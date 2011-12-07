package PVE::QemuMigrate;

use strict;
use warnings;
use PVE::AbstractMigrate;
use IO::File;
use IPC::Open2;
use PVE::INotify;
use PVE::Cluster;
use PVE::Storage;
use PVE::QemuServer;

use base qw(PVE::AbstractMigrate);

sub fork_command_pipe {
    my ($self, $cmd) = @_;

    my $reader = IO::File->new();
    my $writer = IO::File->new();

    my $orig_pid = $$;

    my $cpid;

    eval { $cpid = open2($reader, $writer, @$cmd); };

    my $err = $@;

    # catch exec errors
    if ($orig_pid != $$) {
	$self->log('err', "can't fork command pipe\n");
	POSIX::_exit(1);
	kill('KILL', $$);
    }

    die $err if $err;

    return { writer => $writer, reader => $reader, pid => $cpid };
}

sub finish_command_pipe {
    my ($self, $cmdpipe) = @_;

    my $writer = $cmdpipe->{writer};
    my $reader = $cmdpipe->{reader};

    $writer->close();
    $reader->close();

    my $cpid = $cmdpipe->{pid};

    kill(15, $cpid) if kill(0, $cpid);

    waitpid($cpid, 0);
}

sub run_with_timeout {
    my ($timeout, $code, @param) = @_;

    die "got timeout\n" if $timeout <= 0;

    my $prev_alarm;

    my $sigcount = 0;

    my $res;

    eval {
	local $SIG{ALRM} = sub { $sigcount++; die "got timeout\n"; };
	local $SIG{PIPE} = sub { $sigcount++; die "broken pipe\n" };
	local $SIG{__DIE__};   # see SA bug 4631

	$prev_alarm = alarm($timeout);

	$res = &$code(@param);

	alarm(0); # avoid race conditions
    };

    my $err = $@;

    alarm($prev_alarm) if defined($prev_alarm);

    die "unknown error" if $sigcount && !$err; # seems to happen sometimes

    die $err if $err;

    return $res;
}

sub fork_tunnel {
    my ($self, $nodeip, $lport, $rport) = @_;

    my $cmd = [@{$self->{rem_ssh}}, '-L', "$lport:localhost:$rport",
	       'qm', 'mtunnel' ];

    my $tunnel = $self->fork_command_pipe($cmd);

    my $reader = $tunnel->{reader};

    my $helo;
    eval {
	run_with_timeout(60, sub { $helo = <$reader>; });
	die "no reply\n" if !$helo;
	die "no quorum on target node\n" if $helo =~ m/^no quorum$/;
	die "got strange reply from mtunnel ('$helo')\n"
	    if $helo !~ m/^tunnel online$/;
    };
    my $err = $@;

    if ($err) {
	$self->finish_command_pipe($tunnel);
	die "can't open migration tunnel - $err";
    }
    return $tunnel;
}

sub finish_tunnel {
    my ($self, $tunnel) = @_;

    my $writer = $tunnel->{writer};

    eval {
	run_with_timeout(30, sub {
	    print $writer "quit\n";
	    $writer->flush();
	});
    };
    my $err = $@;

    $self->finish_command_pipe($tunnel);

    die $err if $err;
}

sub lock_vm {
    my ($self, $vmid, $code, @param) = @_;
    
    return PVE::QemuServer::lock_config($vmid, $code, @param);
}

sub prepare {
    my ($self, $vmid) = @_;

    my $online = $self->{opts}->{online};

    $self->{storecfg} = PVE::Storage::config();

    # test is VM exist
    my $conf = $self->{vmconf} = PVE::QemuServer::load_config($vmid);

    PVE::QemuServer::check_lock($conf);

    my $running = 0;
    if (my $pid = PVE::QemuServer::check_running($vmid)) {
	die "cant migrate running VM without --online\n" if !$online;
	$running = $pid;
    }

    if (my $loc_res = PVE::QemuServer::check_local_resources($conf, 1)) {
	if ($self->{running} || !$self->{opts}->{force}) {
	    die "can't migrate VM which uses local devices\n";
	} else {
	    $self->log('info', "migrating VM which uses local devices");
	}
    }

    # activate volumes
    my $vollist = PVE::QemuServer::get_vm_volumes($conf);
    PVE::Storage::activate_volumes($self->{storecfg}, $vollist);

    # fixme: check if storage is available on both nodes

    # test ssh connection
    my $cmd = [ @{$self->{rem_ssh}}, '/bin/true' ];
    eval { $self->cmd_quiet($cmd); };
    die "Can't connect to destination address using public key\n" if $@;

    return $running;
}

sub sync_disks {
    my ($self, $vmid) = @_;

    $self->log('info', "copying disk images");

    my $conf = $self->{vmconf};

    $self->{volumes} = [];

    my $res = [];

    eval {

	my $volhash = {};
	my $cdromhash = {};

	# get list from PVE::Storage (for unused volumes)
	my $dl = PVE::Storage::vdisk_list($self->{storecfg}, undef, $vmid);
	PVE::Storage::foreach_volid($dl, sub {
	    my ($volid, $sid, $volname) = @_;

	    # check if storage is available on both nodes
	    my $scfg = PVE::Storage::storage_check_node($self->{storecfg}, $sid);
	    PVE::Storage::storage_check_node($self->{storecfg}, $sid, $self->{node});

	    return if $scfg->{shared};

	    $volhash->{$volid} = 1;
	});

	# and add used,owned/non-shared disks (just to be sure we have all)

	my $sharedvm = 1;
	PVE::QemuServer::foreach_drive($conf, sub {
	    my ($ds, $drive) = @_;

	    my $volid = $drive->{file};
	    return if !$volid;

	    die "cant migrate local file/device '$volid'\n" if $volid =~ m|^/|;

	    if (PVE::QemuServer::drive_is_cdrom($drive)) {
		die "cant migrate local cdrom drive\n" if $volid eq 'cdrom';
		return if $volid eq 'none';
		$cdromhash->{$volid} = 1;
	    }

	    my ($sid, $volname) = PVE::Storage::parse_volume_id($volid);

	    # check if storage is available on both nodes
	    my $scfg = PVE::Storage::storage_check_node($self->{storecfg}, $sid);
	    PVE::Storage::storage_check_node($self->{storecfg}, $sid, $self->{node});

	    return if $scfg->{shared};

	    die "can't migrate local cdrom '$volid'\n" if $cdromhash->{$volid};

	    $sharedvm = 0;

	    my ($path, $owner) = PVE::Storage::path($self->{storecfg}, $volid);

	    die "can't migrate volume '$volid' - owned by other VM (owner = VM $owner)\n"
		if !$owner || ($owner != $self->{vmid});

	    $volhash->{$volid} = 1;
	});

	if ($self->{running} && !$sharedvm) {
	    die "can't do online migration - VM uses local disks\n";
	}

	# do some checks first
	foreach my $volid (keys %$volhash) {
	    my ($sid, $volname) = PVE::Storage::parse_volume_id($volid);
	    my $scfg =  PVE::Storage::storage_config($self->{storecfg}, $sid);

	    die "can't migrate '$volid' - storagy type '$scfg->{type}' not supported\n"
		if $scfg->{type} ne 'dir';
	}

	foreach my $volid (keys %$volhash) {
	    my ($sid, $volname) = PVE::Storage::parse_volume_id($volid);
	    push @{$self->{volumes}}, $volid;
	    PVE::Storage::storage_migrate($self->{storecfg}, $volid, $self->{nodeip}, $sid);
	}
    };
    die "Failed to sync data - $@" if $@;
}

sub phase1 {
    my ($self, $vmid) = @_;

    $self->log('info', "starting migration of VM $vmid to node '$self->{node}' ($self->{nodeip})");

    my $conf = $self->{vmconf};

    # set migrate lock in config file
    PVE::QemuServer::change_config_nolock($vmid, { lock => 'migrate' }, {}, 1);

    sync_disks($self, $vmid);

    # move config to remote node
    my $conffile = PVE::QemuServer::config_file($vmid);
    my $newconffile = PVE::QemuServer::config_file($vmid, $self->{node});

    die "Failed to move config to node '$self->{node}' - rename failed: $!\n"
	if !rename($conffile, $newconffile);
};

sub phase1_cleanup {
    my ($self, $vmid, $err) = @_;

    $self->log('info', "aborting phase 1 - cleanup resources");

    my $unset = { lock => 1 };
    eval { PVE::QemuServer::change_config_nolock($vmid, {}, $unset, 1) };
    if (my $err = $@) {
	$self->log('err', $err);
    }
  
    if ($self->{volumes}) {
	foreach my $volid (@{$self->{volumes}}) {
	    $self->log('err', "found stale volume copy '$volid' on node '$self->{node}'");
	    # fixme: try to remove ?
	}
    }
}

sub phase2 {
    my ($self, $vmid) = @_;

    my $conf = $self->{vmconf};

    $self->log('info', "starting VM $vmid on remote node '$self->{node}'");

    my $rport;

    ## start on remote node
    my $cmd = [@{$self->{rem_ssh}}, 'qm', 'start', 
	       $vmid, '--stateuri', 'tcp', '--skiplock'];

    $self->cmd($cmd, outfunc => sub {
	my $line = shift;

	if ($line =~ m/^migration listens on port (\d+)$/) {
	    $rport = $1;
	}
    });

    die "unable to detect remote migration port\n" if !$rport;

    $self->log('info', "starting migration tunnel");

    ## create tunnel to remote port
    my $lport = PVE::QemuServer::next_migrate_port();
    $self->{tunnel} = $self->fork_tunnel($self->{nodeip}, $lport, $rport);

    $self->log('info', "starting online/live migration");
    # start migration

    my $start = time();

    PVE::QemuServer::vm_monitor_command($vmid, "migrate -d \"tcp:localhost:$lport\"", 1);

    my $lstat = '';
    while (1) {
	sleep (2);
	my $stat = PVE::QemuServer::vm_monitor_command($vmid, "info migrate", 1);
	if ($stat =~ m/^Migration status: (active|completed|failed|cancelled)$/im) {
	    my $ms = $1;

	    if ($stat ne $lstat) {
		if ($ms eq 'active') {
		    my ($trans, $rem, $total) = (0, 0, 0);
		    $trans = $1 if $stat =~ m/^transferred ram: (\d+) kbytes$/im;
		    $rem = $1 if $stat =~ m/^remaining ram: (\d+) kbytes$/im;
		    $total = $1 if $stat =~ m/^total ram: (\d+) kbytes$/im;

		    $self->log('info', "migration status: $ms (transferred ${trans}KB, " .
			       "remaining ${rem}KB), total ${total}KB)");
		} else {
		    $self->log('info', "migration status: $ms");
		}
	    }

	    if ($ms eq 'completed') {
		my $delay = time() - $start;
		if ($delay > 0) {
		    my $mbps = sprintf "%.2f", $conf->{memory}/$delay;
		    $self->log('info', "migration speed: $mbps MB/s");
		}
	    }
	    
	    if ($ms eq 'failed' || $ms eq 'cancelled') {
		die "aborting\n"
	    }

	    last if $ms ne 'active';
	} else {
	    die "unable to parse migration status '$stat' - aborting\n";
	}
	$lstat = $stat;
    };
}

sub phase3 {
    my ($self, $vmid) = @_;
    
    my $volids = $self->{volumes};

    # destroy local copies
    foreach my $volid (@$volids) {
	eval { PVE::Storage::vdisk_free($self->{storecfg}, $volid); };
	if (my $err = $@) {
	    $self->log('err', "removing local copy of '$volid' failed - $err");
	    $self->{errors} = 1;
	    last if $err =~ /^interrupted by signal$/;
	}
    }

    if ($self->{tunnel}) {
	eval { finish_tunnel($self, $self->{tunnel});  };
	if (my $err = $@) {
	    $self->log('err', $err);
	    $self->{errors} = 1;
	}
    }
}

sub phase3_cleanup {
    my ($self, $vmid, $err) = @_;

    my $conf = $self->{vmconf};

    # always stop local VM
    eval { PVE::QemuServer::vm_stop($self->{storecfg}, $vmid, 1, 1); };
    if (my $err = $@) {
	$self->log('err', "stopping vm failed - $err");
	$self->{errors} = 1;
    }

    # always deactivate volumes - avoid lvm LVs to be active on several nodes
    eval {
	my $vollist = PVE::QemuServer::get_vm_volumes($conf);
	PVE::Storage::deactivate_volumes($self->{storecfg}, $vollist);
    };
    if (my $err = $@) {
	$self->log('err', $err);
	$self->{errors} = 1;
    }

    # clear migrate lock
    my $cmd = [ @{$self->{rem_ssh}}, 'qm', 'unlock', $vmid ];
    $self->cmd_logerr($cmd, errmsg => "failed to clear migrate lock");
}

sub final_cleanup {
    my ($self, $vmid) = @_;

    # nothing to do
}

1;
