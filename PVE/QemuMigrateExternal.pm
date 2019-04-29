package PVE::QemuMigrateExternal;

use strict;
use warnings;
use IO::File;
use IPC::Open2;
use POSIX qw( WNOHANG );
use PVE::INotify;
use PVE::Tools;
use PVE::Cluster;
use PVE::Storage;
use PVE::QemuServer;
use Time::HiRes qw( usleep );
use PVE::RPCEnvironment;
use Storable qw(dclone);

use base qw(PVE::QemuMigrate);

sub prepare {
    my ($self, $vmid) = @_;

    my $online = $self->{opts}->{online};

    $self->{storecfg} = PVE::Storage::config();

    # test if VM exists
    my $conf = $self->{vmconf} = PVE::QemuConfig->load_config($vmid);

    PVE::QemuConfig->check_lock($conf);

    my $running = 0;
    if (my $pid = PVE::QemuServer::check_running($vmid)) {
	die "can't migrate running VM without --online\n" if !$online;
	$running = $pid;

	$self->{forcemachine} = PVE::QemuServer::Machine::qemu_machine_pxe($vmid, $conf);
    }

    my $loc_res = PVE::QemuServer::check_local_resources($conf, 1);
    if (scalar @$loc_res) {
	if ($self->{running} || !$self->{opts}->{force}) {
	    die "can't migrate VM which uses local devices: " . join(", ", @$loc_res) . "\n";
	} else {
	    $self->log('info', "migrating VM which uses local devices");
	}
    }

    # test ssh connection
    push @{$self->{rem_ssh}}, '-i', $self->{opts}->{migration_external_sshkey};
    my $cmd = [ @{$self->{rem_ssh}}, '/bin/true' ];

    eval { $self->cmd_quiet($cmd); };
    die "Can't connect to destination address using public key\n" if $@;

    find_targetvmid($self);

    generate_createvm_cmd($self, $conf);
        
    return 1;

}

sub phase1 {
    my ($self, $vmid) = @_;

    $self->log('info', "starting migration of VM $vmid to node '$self->{node}' ($self->{nodeip})");

    my $conf = $self->{vmconf};

    # set migrate lock in config file
    $conf->{lock} = 'migrate';
    PVE::QemuConfig->write_config($vmid, $conf);

    my $cmd = $self->{createcmd};
    
    # start create vm
    eval{ PVE::Tools::run_command($cmd, outfunc => sub {}, errfunc => sub {}) };
    if (my $err = $@) {
	$self->log('err', $err);
	$self->{errors} = 1;
	die $err;
    }
}

sub phase1_cleanup {
    my ($self, $vmid, $err) = @_;

    $self->log('info', "aborting phase 1 - cleanup resources");

    my $targetvmid = $self->{opts}->{targetvmid} ? $self->{opts}->{targetvmid} : $vmid;
	
    PVE::QemuMigrate::unlock_vm($self, $vmid);

    cleanup_remote_vm($self, $targetvmid);
}


sub phase2 {
    my ($self, $vmid) = @_;

    my $targetvmid = $self->{opts}->{targetvmid} ? $self->{opts}->{targetvmid} : $vmid;

    my $nodename = PVE::INotify::nodename();
        
    $self->log('info', "starting VM $vmid on remote node '$self->{node}'");

    my $migration_type = 'secure';

    my $cmd = generate_migrate_start_cmd($self, $targetvmid, $nodename, $migration_type);
    
    my ($raddr, $rport, $ruri, $spice_port, $spice_ticket) = PVE::QemuMigrate::find_remote_ports($self, $targetvmid, $cmd);

    PVE::QemuMigrate::start_remote_tunnel($self, $nodename, $migration_type, $raddr, $rport, $ruri);

    livemigrate_storage($self, $vmid);
    
    PVE::QemuMigrate::livemigrate($self, $vmid, $ruri, $spice_port);
    
}

sub phase2_cleanup {
    my ($self, $vmid, $err) = @_;

    return if !$self->{errors};

    my $targetvmid = $self->{opts}->{targetvmid} ? $self->{opts}->{targetvmid} : $vmid;

    $self->{phase2errors} = 1;

    $self->log('info', "aborting phase 2 - cleanup resources");

    PVE::QemuMigrate::cancel_migrate($self, $vmid);

    PVE::QemuMigrate::unlock_vm($self, $vmid);

    cleanup_remote_vm($self, $targetvmid);

    if ($self->{tunnel}) {
	eval { PVE::QemuMigrate::finish_tunnel($self, $self->{tunnel});  };
	if (my $err = $@) {
	    $self->log('err', $err);
	    $self->{errors} = 1;
	}
    }
}


sub phase3_cleanup {
    my ($self, $vmid, $err) = @_;

    return if $self->{phase2errors};
        
    my $targetvmid = $self->{opts}->{targetvmid} ? $self->{opts}->{targetvmid} : $vmid;

    finish_block_jobs($self, $vmid);
        
    PVE::QemuMigrate::finish_livemigration($self, $targetvmid);
    
    PVE::QemuMigrate::finish_spice_migration($self, $vmid);

    PVE::QemuMigrate::stop_local_vm($self, $vmid);

    # clear migrate lock
    my $cmd = [ @{$self->{rem_ssh}}, 'qm', 'unlock', $targetvmid ];
    $self->cmd_logerr($cmd, errmsg => "failed to clear migrate lock");
}

sub find_targetvmid {
    my ($self) = @_;
    
    if (!$self->{opts}->{targetvmid}) {
	#get remote nextvmid
	eval {
	    my $cmd = [@{$self->{rem_ssh}}, 'pvesh', 'get', '/cluster/nextid'];
	    PVE::Tools::run_command($cmd, outfunc => sub {
		my $line = shift;
		if ($line =~ m/^(\d+)/) {
		    $self->{opts}->{targetvmid} = $line;
		}
	    });
	};
	if (my $err = $@) {
	    $self->log('err', $err);
	    $self->{errors} = 1;
	    die $err;
	}

	die "can't find the next free vmid on remote cluster\n" if !$self->{opts}->{targetvmid};
    }

}

sub generate_createvm_cmd {
    my ($self, $conf) = @_;
    
    my $cmd = [@{$self->{rem_ssh}}, 'qm', 'create', $self->{opts}->{targetvmid}];

    my $target_conf = dclone $conf;

    foreach my $opt (keys %{$target_conf}) {
	next if $opt =~ m/^(pending|snapshots|digest|parent)/;
	next if $opt =~ m/^(ide|scsi|virtio)(\d+)/;

	if ($opt =~ m/^(net)(\d+)/ && $self->{opts}->{$opt}) {
	    my $oldnet = PVE::QemuServer::parse_net($target_conf->{$opt});
	    my $newnet = PVE::QemuServer::parse_net($self->{opts}->{$opt});
	    foreach my $newnet_opt (keys %$newnet) {
		next if $newnet_opt =~ m/^(model|macaddr|queues)$/;
		$oldnet->{$newnet_opt} = $newnet->{$newnet_opt};
	    }
	    $target_conf->{$opt} = PVE::QemuServer::print_net($oldnet);
	}

	die "can't migrate unused disk. please remove it before migrate\n" if $opt =~ m/^(unused)(\d+)/;
	push @$cmd , "-$opt", PVE::Tools::shellquote($target_conf->{$opt});
    }

    PVE::QemuServer::foreach_drive($target_conf, sub {
	my ($ds, $drive) = @_;

	if (PVE::QemuServer::drive_is_cdrom($drive, 1)) {
	    push @$cmd , "-$ds", PVE::Tools::shellquote($target_conf->{$ds});
	    return;
	}

	my $volid = $drive->{file};
	return if !$volid;

	my ($sid, $volname) = PVE::Storage::parse_volume_id($volid, 1);
	return if !$sid;
	my $size = PVE::Storage::volume_size_info($self->{storecfg}, $volid, 5);
	die "can't get size\n" if !$size;
	$size = $size/1024/1024/1024;
	my $targetsid = $self->{opts}->{targetstorage} ? $self->{opts}->{targetstorage} : $sid;

	my $data = { %$drive };
	delete $data->{$_} for qw(index interface file size);
	my $drive_conf = "$targetsid:$size";
	foreach my $drive_opt (keys %{$data}) {
	    $drive_conf .= ",$drive_opt=$data->{$drive_opt}";
	}

	push @$cmd , "-$ds", PVE::Tools::shellquote($drive_conf);
    });

    push @$cmd , '-lock', 'migrate';

    $self->{createcmd} = $cmd;
}

sub generate_migrate_start_cmd {
    my ($self, $vmid, $nodename, $migration_type) = @_;

    my $cmd = [@{$self->{rem_ssh}}];

    push @$cmd , 'qm', 'start', $vmid, '--skiplock';

    push @$cmd, '--external_migration';
        
    push @$cmd, '--migration_type', $migration_type;

    push @$cmd, '--migration_network', $self->{opts}->{migration_network}
      if $self->{opts}->{migration_network};

    if ($migration_type eq 'insecure') {
	push @$cmd, '--stateuri', 'tcp';
    } else {
	push @$cmd, '--stateuri', 'unix';
    }

    if ($self->{forcemachine}) {
	push @$cmd, '--machine', $self->{forcemachine};
    }

    if ($self->{online_local_volumes}) {
	push @$cmd, '--targetstorage', ($self->{opts}->{targetstorage} // '1');
    }
    
    return $cmd;
}

sub livemigrate_storage {
    my ($self, $vmid) = @_;

    my $conf = $self->{vmconf};

	$self->{storage_migration} = 1;
	$self->{storage_migration_jobs} = {};
	$self->log('info', "starting storage migration");
	foreach my $drive (keys %{$self->{target_drive}}){
	    my $target = $self->{target_drive}->{$drive};
	    my $nbd_uri = $target->{nbd_uri};
	    #bandwith, source only
	    my $source_sid = PVE::Storage::Plugin::parse_volume_id($conf->{$drive});
	    my $bwlimit = PVE::Storage::get_bandwidth_limit('migrate', [$source_sid, undef], $self->{opts}->{bwlimit});
	    $self->log('info', "$drive: start migration to $nbd_uri");
	    PVE::QemuServer::qemu_drive_mirror($vmid, $drive, $nbd_uri, $vmid, undef, $self->{storage_migration_jobs}, 1, undef, $bwlimit);
	}

}

sub finish_block_jobs {
    my ($self, $vmid) = @_;

    my $conf = $self->{vmconf};

    if ($self->{storage_migration}) {
	# finish block-job
	eval { PVE::QemuServer::qemu_drive_mirror_monitor($vmid, undef, $self->{storage_migration_jobs}); };

	if (my $err = $@) {
	    eval { PVE::QemuServer::qemu_blockjobs_cancel($vmid, $self->{storage_migration_jobs}) };
	    eval { PVE::QemuMigrate::cleanup_remotedisks($self) };
	    die "Failed to completed storage migration\n";
	}
    }    
}


sub cleanup_remote_vm {
    my ($self, $vmid) = @_;
    
    my $cmd = [@{$self->{rem_ssh}}, 'qm', 'stop', $vmid, '--skiplock'];

    eval{ PVE::Tools::run_command($cmd, outfunc => sub {}, errfunc => sub {}) };
    if (my $err = $@) {
        $self->log('err', $err);
        $self->{errors} = 1;
    }

    $cmd = [@{$self->{rem_ssh}}, 'qm', 'destroy', $vmid, '--skiplock'];

    eval{ PVE::Tools::run_command($cmd, outfunc => sub {}, errfunc => sub {}) };
    if (my $err = $@) {
	$self->log('err', $err);
	$self->{errors} = 1;
    }
}

1;
