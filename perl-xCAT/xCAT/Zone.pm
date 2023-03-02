#!/usr/bin/env perl
# IBM(c) 2007 EPL license http://www.eclipse.org/legal/epl-v10.html
package xCAT::Zone;

BEGIN
{
    $::XCATROOT = $ENV{'XCATROOT'} ? $ENV{'XCATROOT'} : '/opt/xcat';
}

# if AIX - make sure we include perl 5.8.2 in INC path.
#       Needed to find perl dependencies shipped in deps tarball.
if ($^O =~ /^aix/i) {
    unshift(@INC, qw(/usr/opt/perl5/lib/5.8.2/aix-thread-multi /usr/opt/perl5/lib/5.8.2 /usr/opt/perl5/lib/site_perl/5.8.2/aix-thread-multi /usr/opt/perl5/lib/site_perl/5.8.2));
}

use lib "$::XCATROOT/lib/perl";

# do not put a use or require for  xCAT::Table here. Add to each new routine
# needing it to avoid reprocessing of user tables ( ExtTab.pm) for each command call
use POSIX qw(ceil);
use File::Path;
use Socket;
use strict;
use Symbol;
use warnings "all";

#--------------------------------------------------------------------------------

=head1    xCAT::Zone

=head2    Package Description

This program module file, is a set of Zone utilities used by xCAT *zone commands.

=cut


#--------------------------------------------------------------------------------

=head3    genSSHRootKeys
    Arguments:
      callback for error messages
      directory in which to put the ssh RSA keys
      zonename
      rsa private key to use for generation ( optional)
    Returns:
    Error:  1 - key generation failure.
    Example:
     $rc =xCAT::Zone->genSSHRootKeys($callback,$keydir,$rsakey);
=cut

#--------------------------------------------------------------------------------
sub genSSHRootKeys
{
    my ($class, $callback, $keydir, $zonename, $rsakey) = @_;

    #
    # create /keydir if needed
    #
    if (!-d $keydir)
    {
        my $cmd = "/bin/mkdir -m 700 -p $keydir";
        my $output = xCAT::Utils->runcmd("$cmd", 0);
        if ($::RUNCMD_RC != 0)
        {
            my $rsp = {};
            $rsp->{error}->[0] =
              "Could not create $keydir directory";
            xCAT::MsgUtils->message("E", $rsp, $callback);
            return 1;

        }
    }


    #need to gen a new rsa key for root for the zone
    my $pubfile = "$keydir/id_rsa.pub";
    my $pvtfile = "$keydir/id_rsa";

    # if exists, remove the old files
    if (-r $pubfile)
    {

        my $cmd = "/bin/rm $keydir/id_rsa*";
        my $output = xCAT::Utils->runcmd("$cmd", 0);
        if ($::RUNCMD_RC != 0)
        {
            my $rsp = {};
            $rsp->{error}->[0] = "Could not remove id_rsa files from $keydir directory.";
            xCAT::MsgUtils->message("E", $rsp, $callback);
            return 1;
        }
    }

    # gen new RSA keys
    my $cmd;
    my $output;

    # if private key was input use it
    if (defined($rsakey)) {
        $cmd = "/usr/bin/ssh-keygen -y -f $rsakey > $pubfile";
        $output = xCAT::Utils->runcmd("$cmd", 0);
        if ($::RUNCMD_RC != 0)
        {
            my $rsp = {};
            $rsp->{error}->[0] = "Could not generate $pubfile from $rsakey";
            xCAT::MsgUtils->message("E", $rsp, $callback);
            return 1;
        }

        # now copy the private key into the directory
        $cmd = "cp $rsakey  $keydir";
        $output = xCAT::Utils->runcmd("$cmd", 0);
        if ($::RUNCMD_RC != 0)
        {
            my $rsp = {};
            $rsp->{error}->[0] = "Could not run $cmd";
            xCAT::MsgUtils->message("E", $rsp, $callback);
            return 1;
        }
    } else {    # generate all new keys
        $cmd = "/usr/bin/ssh-keygen -t rsa -q -b 2048 -N '' -f $pvtfile";
        $output = xCAT::Utils->runcmd("$cmd", 0);
        if ($::RUNCMD_RC != 0)
        {
            my $rsp = {};
            $rsp->{error}->[0] = "Could not generate $pubfile";
            xCAT::MsgUtils->message("E", $rsp, $callback);
            return 1;
        }
    }

    #make sure permissions are correct
    $cmd = "chmod 644 $pubfile;chown root $pubfile";
    $output = xCAT::Utils->runcmd("$cmd", 0);
    if ($::RUNCMD_RC != 0)
    {
        my $rsp = {};
        $rsp->{error}->[0] = "Could set permission and owner on  $pubfile";
        xCAT::MsgUtils->message("E", $rsp, $callback);
        return 1;
    }
}

#--------------------------------------------------------------------------------

=head3    getdefaultzone
    Arguments:
      None
    Returns:
    Name of the current default  zone from the zone table
    Example:
     my $defaultzone =xCAT::Zone->getdefaultzone($callback);
=cut

#--------------------------------------------------------------------------------
sub getdefaultzone
{
    my ($class, $callback) = @_;
    my $defaultzone;

    # read all the zone table and find the defaultzone, if it exists
    my $tab = xCAT::Table->new("zone");
    if ($tab) {
        my @zones = $tab->getAllAttribs('zonename', 'defaultzone');
        foreach my $zone (@zones) {

            # Look for the  defaultzone=yes/1 entry
            if ((defined($zone->{defaultzone})) &&
                (($zone->{defaultzone} =~ /^yes$/i)
                    || ($zone->{defaultzone} eq "1"))) {
                $defaultzone = $zone->{zonename};
            }
            $tab->close();
        }
    } else {
        my $rsp = {};
        $rsp->{error}->[0] =
          "Error reading the zone table. ";
        xCAT::MsgUtils->message("E", $rsp, $callback);

    }
    return $defaultzone;
}

#--------------------------------------------------------------------------------

=head3    iszonedefined
    Arguments:
      zonename
    Returns:
     1 if the zone is already in the zone table.
    Example:
     xCAT::Zone->iszonedefined($zonename);
=cut

#--------------------------------------------------------------------------------
sub iszonedefined
{
    my ($class, $zonename) = @_;

    # checks the zone table to see if input zonename already in the table
    my $tab = xCAT::Table->new("zone");
    $tab->close();
    my $zonehash = $tab->getAttribs({ zonename => $zonename }, 'sshkeydir');
    if (keys %$zonehash) {
        return 1;
    } else {
        return 0;
    }
}

#--------------------------------------------------------------------------------

=head3  getzonekeydir
    Arguments:
      zonename
    Returns:
     path to the root ssh keys for the zone /etc/xcat/sshkeys/<zonename>/.ssh
     1 - zone not defined
    Example:
     xCAT::Zone->getzonekeydir($zonename);
=cut

#--------------------------------------------------------------------------------
sub getzonekeydir
{
    my ($class, $zonename) = @_;
    my $tab = xCAT::Table->new("zone");
    $tab->close();
    my $zonehash = $tab->getAttribs({ zonename => $zonename }, 'sshkeydir');
    if (keys %$zonehash) {
        my $zonesshkeydir = $zonehash->{sshkeydir};
        return $zonesshkeydir;
    } else {
        return 1;    # this is a bad error  zone not defined
    }
}

#--------------------------------------------------------------------------------

=head3    getmyzonename
    Arguments:
       $node -one nodename
    Returns:
     $zonename
    Example:
     my $zonename=xCAT::Zone->getmyzonename($node);
=cut

#--------------------------------------------------------------------------------
sub getmyzonename
{
    my ($class, $node, $callback) = @_;
    my @node;
    push @node, $node;
    my $zonename;
    my $nodelisttab = xCAT::Table->new("nodelist");
    my $nodehash = $nodelisttab->getNodesAttribs(\@node, ['zonename']);
    $nodelisttab->close();
    if (defined($nodehash->{$node}->[0]->{zonename})) { # it was defined in the nodelist table
        $zonename = $nodehash->{$node}->[0]->{zonename};
    } else {                                            # get the default zone
        $zonename = xCAT::Zone->getdefaultzone($callback);
    }
    return $zonename;
}

#--------------------------------------------------------------------------------

=head3    enableSSHbetweennodes
    Arguments:
      nodename
    Returns:
     1 if the  sshbetweennodes attribute is yes/1 or undefined
     0 if the  sshbetweennodes attribute is no/0
    Example:
     xCAT::Zone->enableSSHbetweennodes($nodename);
=cut

#--------------------------------------------------------------------------------
sub enableSSHbetweennodes
{
    my ($class, $node, $callback) = @_;

    # finds the zone of the node
    my $enablessh = 1;                                  # default
    my $zonename  = xCAT::Zone->getmyzonename($node);

    # reads the zone table
    my $tab = xCAT::Table->new("zone");
    $tab->close();

    # read both keys,  want to know zone is in the zone table. If sshkeydir is not there
    # it is either missing or invalid anyway
    my $zonehash = $tab->getAttribs({ zonename => $zonename }, 'sshbetweennodes', 'sshkeydir');
    if (!(keys %$zonehash)) {
        my $rsp = {};
        $rsp->{error}->[0] =
"$node has a  zonename: $zonename that is  not define in the zone table. Remove the zonename from the node, or create the zone using mkzone. The generated mypostscript may not reflect the correct setting for  ENABLESSHBETWEENNODES";
        xCAT::MsgUtils->message("E", $rsp, $callback);
        return $enablessh;
    }
    my $sshbetweennodes = $zonehash->{sshbetweennodes};
    if (defined($sshbetweennodes)) {
        if (($sshbetweennodes =~ /^no$/i) || ($sshbetweennodes eq "0")) {
            $enablessh = 0;
        } else {
            $enablessh = 1;
        }
    } else {    # not defined default yes
        $enablessh = 1;    # default
    }
    return $enablessh;
}

#--------------------------------------------------------------------------------

=head3    usingzones
    Arguments:
      none
    Returns:
     1 if the zone table is not empty
     0 if empty
    Example:
     xCAT::Zone->usingzones;
=cut

#--------------------------------------------------------------------------------
sub usingzones
{
    my ($class) = @_;

    # reads the zonetable
    my $tab  = xCAT::Table->new("zone");
    my @zone = $tab->getAllAttribs('zonename');
    $tab->close();
    if (@zone) {
        return 1;
    } else {
        return 0;
    }
}

#--------------------------------------------------------------------------------

=head3    getzoneinfo
    Arguments:
     callback
     An array of nodes
    Returns:
     Hash array  by zonename point to the nodes in that zonename  and sshkeydir
      <zonename1> -> {nodelist} -> array of nodes in the zone
                 -> {sshkeydir} -> directory containing ssh RSA keys
                 -> {defaultzone} ->  is it the default zone
    Example:
     my %zonehash =xCAT::Zone->getzoneinfo($callback,@nodearray);
    Rules:
       If the nodes nodelist.zonename attribute is a zonename, it is assigned to that zone
       If the nodes nodelist.zonename attribute is undefined:
          If there is a defaultzone in the zone table, the node is assigned to that zone
          If there is no defaultzone in the zone table, the node is assigned to the ~.ssh keydir
    $::GETZONEINFO_RC
           0 = good return
           1 = error occured
=cut

#--------------------------------------------------------------------------------
sub getzoneinfo
{
    my ($class, $callback, $nodes) = @_;
    $::GETZONEINFO_RC = 0;
    my $zonehash;
    my $defaultzone;

    # read all the zone table
    my $zonetab = xCAT::Table->new("zone");
    my @zones;
    if ($zonetab) {
        @zones = $zonetab->getAllAttribs('zonename', 'sshkeydir', 'sshbetweennodes', 'defaultzone');
        $zonetab->close();
        if (@zones) {
            foreach my $zone (@zones) {
                my $zonename = $zone->{zonename};
                $zonehash->{$zonename}->{sshkeydir}   = $zone->{sshkeydir};
                $zonehash->{$zonename}->{defaultzone} = $zone->{defaultzone};
                $zonehash->{$zonename}->{sshbetweennodes} = $zone->{sshbetweennodes};

                # find the defaultzone
                if ((defined($zone->{defaultzone})) &&
                    (($zone->{defaultzone} =~ /^yes$/i)
                        || ($zone->{defaultzone} eq "1"))) {
                    $defaultzone = $zone->{zonename};
                }
            }
        }
    } else {
        my $rsp = {};
        $rsp->{error}->[0] =
          "Error reading the zone table. ";
        xCAT::MsgUtils->message("E", $rsp, $callback);
        $::GETZONEINFO_RC = 1;
        return;

    }
    my $nodelisttab = xCAT::Table->new("nodelist");
    my $nodehash = $nodelisttab->getNodesAttribs(\@$nodes, ['zonename']);

    # for each of the nodes, look up it's zone name and assign to the zonehash
    # If the nodes nodelist.zonename attribute is a zonename, it is assigned to that zone
    # If the nodes nodelist.zonename attribute is undefined:
    #         If there is a defaultzone in the zone table, the node is assigned to that zone
    #         If there is no defaultzone error out


    foreach my $node (@$nodes) {
        my $zonename;
        $zonename = $nodehash->{$node}->[0]->{zonename};
        if (defined($zonename)) { # zonename explicitly defined in nodelist.zonename
                                  # check to see if defined in the zone table
            unless (xCAT::Zone->iszonedefined($zonename)) {
                my $rsp = {};
                $rsp->{error}->[0] =
"$node has a  zonename: $zonename that is  not define in the zone table. Remove the zonename from the node, or create the zone using mkzone.";
                xCAT::MsgUtils->message("E", $rsp, $callback);
                $::GETZONEINFO_RC = 1;
                return;
            }
            push @{ $zonehash->{$zonename}->{nodes} }, $node;
        } else {                  # no explict zonename
            if (defined($defaultzone)) { # there is a default zone in the zone table, use it
                push @{ $zonehash->{$defaultzone}->{nodes} }, $node;
            } else {                     # if no default, this is an error
                my $rsp = {};
                $rsp->{error}->[0] =
"There is no default zone defined in the zone table. There must be exactly one default zone. ";
                xCAT::MsgUtils->message("E", $rsp, $callback);
                $::GETZONEINFO_RC = 1;
                return;

            }
        }
    }
    return $zonehash;
}

#--------------------------------------------------------------------------------

=head3    getnodesinzone
    Arguments:
     callback
     zonename
    Returns:
     Array of nodes
    Example:
     my @nodes =xCAT::Zone->getnodesinzone($callback,$zonename);
=cut

#--------------------------------------------------------------------------------
sub getnodesinzone
{
    my ($class, $callback, $zonename) = @_;
    my @nodes;
    my $nodelisttab = xCAT::Table->new("nodelist");
    my @nodelist = $nodelisttab->getAllAttribs('node', 'zonename');

    # build the array of nodes in this zone
    foreach my $nodename (@nodelist) {
        if ((defined($nodename->{'zonename'})) && ($nodename->{'zonename'} eq $zonename)) {
            push @nodes, $nodename->{'node'};
        }
    }
    return @nodes;
}
1;
