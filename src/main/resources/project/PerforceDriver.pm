####################################################################
####################################################################
# ECSCM::Perforce::Driver  Object to represent interactions with
#        perforce.
#
#  Functionality pulled from ecp4snapshot and ElectricSentry.pl
#   Todo:  some duplication of client spec creation could be refactored
####################################################################
package ECSCM::Perforce::Driver;
@ISA = (ECSCM::Base::Driver);
use ElectricCommander;
use Time::Local;
use File::Basename;
use File::Copy;
use File::Path;
use File::Spec;
use File::stat;
use File::Temp;
use File::Find;
use FindBin;
use Sys::Hostname;
use File::Temp qw{tempfile};
use Cwd;
use Getopt::Long;
#use strict;
$| = 1;

BEGIN {
    eval {
        require "open.pm";
        1;
    } and do {
        open::import('open', ":encoding(UTF-8)");
        open::import('open', IO => ":encoding(UTF-8)");
    }
}

####################################################################
# Object constructor for ECSCM::Perforce::Driver
#
# Inputs
#    cmdr          previously initialized ElectricCommander handle
#    name          name of this configuration
#
####################################################################
sub new {
    my $this  = shift;
    my $class = ref($this)
        || $this;
    my $cmdr = shift;
    my $name = shift;
    #flag for login status
    my $cfg  = new ECSCM::Perforce::Cfg( $cmdr, "$name" );
    if ( "$name" ne "" ) {
        my $sys = $cfg->getSCMPluginName();
        if ( "$sys" ne "ECSCM-Perforce" ) {
            die "SCM config $name is not type ECSCM-Perforce";
        }
    }
    my ($self) = new ECSCM::Base::Driver( $cmdr, $cfg );
    bless( $self, $class );
    return $self;
}
####################################################################
# isImplemented
####################################################################
sub isImplemented {
    my ( $self, $method ) = @_;
    if (   $method eq 'getSCMTag'
        || $method eq 'checkoutCode'
        || $method eq 'apf_driver'
        || $method eq 'cpf_driver' )
    {
        return 1;
    }
    else {
        return 0;
    }
}
###############################################################################
# ElectricSentry (continuous integration) routines
###############################################################################
####################################################################
# getSCMTag
#
# Get the latest changelist on this branch/client
# Used for CI
#
# Args:
#   opts  - options passed in from caller
# Return:
#    changeNumber - a string representing the last change sequence #
#    changeTime   - a time stamp representing the time of last change
####################################################################

sub getSCMTag {
    my ( $self, $opts ) = @_;

    $self->updateOptions($opts);
    #set a login flag to avoid authenticating more than once.
    $opts->{loggedIn} = "0";

    # Load userName and password from the credential
    ( $opts->{P4USER}, $opts->{P4PASSWD} )
        = $self->retrieveUserCredential( $opts->{credential}, $opts->{P4USER}, $opts->{P4PASSWD} );
    $self->debugMsg( 1, "P4USER=$opts->{P4USER}", $opts);

    # Get the config on the trigger schedule
    my $clientOrDepotName = $opts->{P4ClientOrDepot};
    my $p4Paths           = $opts->{P4Paths};
    my $p4ExcludePaths    = $opts->{P4ExcludePaths};

    # Check for required data
    if ( !length( $clientOrDepotName ))
    {
        if ( "$p4Paths" ne "" ) {
            $clientOrDepotName = $p4Paths;
        }
        else {
            $self->issueWarningMsg("*** No client or depot name was specified in getSCMTag");
            return ( undef, undef );
        }
    }

    # Execute preexecution commands if they exist before executing p4 schedule check
    my $preExecCmds = $opts->{PreExecutionCmd};
    if ( defined $preExecCmds ) {

        #remove leading/trailing spaces
        $preExecCmds =~ s/(^\s+)|(\s+$)//sg;
        if ( "$preExecCmds" ne "" ) {
            my $cmdResult = $self->runPreExecutionCmds($preExecCmds);
            if ( !( defined $cmdResult ) ) {
                $self->issueWarningMsg("*** PreExecutionCmds failed in getSCMTag");
                return ( undef, undef );
            }
        }
    }

    # set the generic p4 command
    my ( $p4Command, $passwordStart, $passwordLength ) = $self->setupP4($opts);

    # Remove leading and trailing spaces
    $clientOrDepotName =~ s/(^\s+)|(\s+$)//sg;

    my ($tempP4ClientName, $viewData)
        = $self->createP4ClientSpecFromView(
              $clientOrDepotName, $p4ExcludePaths,"", $p4Command, "$opts->{P4USER}", undef,undef, undef, $opts, 1, 1 );

    if ( defined $tempP4ClientName
        && $tempP4ClientName eq "-1" )
    {
        $self->issueWarningMsg("*** Error encountered and reported while creating client\n");
        return ( undef, undef );
    }

    my $depotPath = undef;

    if ( defined $tempP4ClientName ) {
        $opts->{temp_client} = $tempP4ClientName;
    }
    elsif ( $clientOrDepotName =~ "^//" ) {
        # Handle the case of a single depot path
        # Add a trailing "/..." to the client or depot name unless it already has it
        $clientOrDepotName .= "/..."
            unless ( $clientOrDepotName =~ '/\.\.\.$' );
        $depotPath = $clientOrDepotName;
    }
    else {
        # Handle the case of where an existing client was specified
        #  NOTE - there is no '@' sign so it returns all of the changesets
        #         AFFECTING the Client, NOT just those that have been
        #         BROUGHT INTO the client
        $opts->{temp_client} = $clientOrDepotName;
    }

    my ($changeNumber, $changeTime) = $self->getP4LastSnapshotId($opts, $depotPath);

    # Delete the temporary spec if it was created
    if ( defined $tempP4ClientName ) {

        # Delete the temporary client
        $self->RunCommand(
            "$p4Command client -d $tempP4ClientName",
            {   IgnoreError    => 1,
                LogCommand     => 1,
                HidePassword   => 1,
                passwordStart  => $passwordStart,
                passwordLength => $passwordLength
            }
        );
    }

    #logging out
    if($opts->{autoLogin} && $opts->{autoLogin} eq "1") {
        $self->p4Logout($opts);
    }

    $self->debugMsg( 1, "Returning from PerforceDriver.pm::getSCMTag with changeNumber: $changeNumber changeTime: $changeTime", $opts);

    return ( $changeNumber, $changeTime );
}

#-------------------------------------------------------------------------
# setupP4
#
# Create the common parts of the perforce command
# This is used on agent side command runs where user/password/port
# must be read from configuration and are not found in
# "p4 set"
#
# Returns
#   p4Command - The command prefix string
#   passwordStart - The starting character of the password
#   passwordLength - The numbr of chars in the password
#-------------------------------------------------------------------------
sub setupP4 {
    my ( $self, $opts ) = @_;
    my $p4Command = "p4";

    if($opts->{autoLogin} && $opts->{autoLogin} eq "1"){
        $ENV{'P4PORT'} = $opts->{P4PORT};
        $ENV{'P4USER'} = $opts->{P4USER};
        $ENV{'P4PASSWD'} = $opts->{P4PASSWD};
        $self->p4Login($opts);
    }

    #  Add P4 parameters
    if ($opts->{P4USER} && $opts->{P4USER} ne "" )
    {
        if(!$opts->{autoLogin} || $opts->{autoLogin} eq "0"){
            $p4Command = $p4Command . " -u $opts->{P4USER}";
        }
    }

    if ($opts->{P4PORT} && $opts->{P4PORT} ne "")
    {
        $p4Command = $p4Command . " -p $opts->{P4PORT}";
    }
    if ($opts->{P4HOST} && $opts->{P4HOST} ne "")
    {
        $p4Command = $p4Command . " -H $opts->{P4HOST}";
    }
    my $passwordStart  = 0;
    my $passwordLength = 0;
    if ($opts->{P4PASSWD} && $opts->{P4PASSWD} ne "" )
    {
        if(!$opts->{autoLogin} || $opts->{autoLogin} eq "0"){
            $p4Command      = $p4Command . " -P ";
            $passwordStart  = length $p4Command;
            $p4Command      = $p4Command . $opts->{P4PASSWD};
            $passwordLength = ( length $p4Command ) - $passwordStart;
        }
    }

    if ($opts->{P4CHARSET} && $opts->{P4CHARSET} ne "")
    {
        $p4Command = $p4Command . " -C $opts->{P4CHARSET}";
    }

    if ($opts->{P4COMMANDCHARSET} && $opts->{P4COMMANDCHARSET} ne "" )
    {
        $p4Command = $p4Command . " -Q $opts->{P4COMMANDCHARSET}";
    }

    if ($opts->{P4TICKETS} && $opts->{P4TICKETS} ne "" )
    {
        $ENV{P4TICKETS} = $opts->{P4TICKETS};
    }

    $self->{p4Command} = $p4Command;
    $self->{passwordStart} = $passwordStart;
    $self->{passwordLength} = $passwordLength;

    return ( $p4Command, $passwordStart, $passwordLength );
}

#-------------------------------------------------------------------------
# runPreExecutionCmds
#-------------------------------------------------------------------------
sub runPreExecutionCmds {
    require File::Temp;
    require File::Spec;
    my ( $self, $myPreExecCmds ) = @_;
    my $cmdResult = "";

    # Write myPreExecCmds to a shell file
    my ( undef, $outputName ) = File::Temp::tempfile(
        "ecsentryprecmd_XXXXXX",
        OPEN   => 0,
        DIR    => File::Spec->tmpdir,
        SUFFIX => ".bat",
        UNLINK => 0
    );
    open( ECPRECMDFILE, ">>$outputName" );
    print ECPRECMDFILE "$myPreExecCmds";
    close(ECPRECMDFILE);
    chmod 0755, $outputName;

    # Execute the query
    my $cmdReturn = $self->RunCommand(
        "$outputName",
        {   LogCommand   => 1,
            LogResult    => 1,
            HidePassword => 1
        }
    );

    # Delete temp shell file
    unlink($outputName);
    return undef
        if ( !( defined $cmdReturn ) );
    $cmdResult = $cmdResult . $cmdReturn;
    return $cmdResult;
}

#-------------------------------------------------------------------------
# createP4ClientSpec
#
# Takes a clientspec provided in a string and creates it on specified perforce server.
#
# Args
#
#   p4Command
#   passwordStart
#   passwordLength
#   p4ClientSpec
#
# Return:
#   1     = success
#   undef = failure
#-------------------------------------------------------------------------
sub createP4ClientSpec {
    my ( $self, $p4Command, $passwordStart, $passwordLength, $p4ClientSpec ) = @_;
    print "Creating P4 Client Spec: $p4ClientSpec\n";

    #write client spec to temp file
    my $stdin    = undef;
    my $tempFile = undef;
    if ( defined($p4ClientSpec)
        && length $p4ClientSpec > 0 )
    {
        my $stdin;
        ( $stdin, $tempFile ) = File::Temp::tempfile(
            "ecp4in_XXXXXX",
            DIR    => File::Spec->tmpdir,
            UNLINK => 0
        );
        print( $stdin $p4ClientSpec );
        close($stdin);
    }

    #create the temporary client
    my $output = $self->RunCommand(
        qq{$p4Command client -i < "$tempFile"},
        {   LogCommand     => 1,
            HidePassword   => 1,
            passwordStart  => $passwordStart,
            passwordLength => $passwordLength
        }
    );
    unlink($tempFile);
    if ( !defined $output ) {
        return undef;
    }
    return 1;
}

#-------------------------------------------------------------------------
# createP4ClientFromStream
#
# Creates a client spec from a Stream name on specified perforce server.
#
# Args
#
#   p4Command
#   passwordStart
#   passwordLength
#   stream
#   clientName
#
# Return:
#   1     = success
#   undef = failure
#-------------------------------------------------------------------------
sub createP4ClientFromStream {
    my ( $self, $p4Command, $passwordStart, $passwordLength, $stream, $name, $dest ) = @_;
    my $base = $self->RunCommand(
        qq{$p4Command client -o -S "$stream" "$name"},
        {   LogCommand     => 1,
            HidePassword   => 1,
            passwordStart  => $passwordStart,
            passwordLength => $passwordLength
        }
    );
    if ( !defined $base ) {
        exit(1);
    }

    #write client spec to temp file
    my $stdin    = undef;
    my $tempFile = undef;
    if ( defined($base)
        && length $base > 0 )
    {
        my $stdin;
        ( $stdin, $tempFile ) = File::Temp::tempfile(
            "ecp4in_XXXXXX",
            DIR    => File::Spec->tmpdir,
            UNLINK => 0
        );
        $base =~ s/\nRoot[^\n]*\n/\nRoot: $dest\n/;
        print( $stdin $base );
        close($stdin);
    }

    #create the temporary client
    my $output = $self->RunCommand(
        qq{$p4Command client -i < "$tempFile"},
        {   LogCommand     => 1,
            HidePassword   => 1,
            passwordStart  => $passwordStart,
            passwordLength => $passwordLength
        }
    );
    unlink($tempFile);
    if ( !defined $output ) {
        return undef;
    }
    return 1;
}

#-------------------------------------------------------------------------
#  createP4ClientSpecFromView
#
#  Examine the passed in depot string to see if it looks like a
#  "multi-depot specification"
#
#  The "multi-depot specification" can contain one or more pairs of
#        depot path and file path
#  There are two ways to specify them for this subroutine.  The preferred way
#  is to separate each pair with a new line and to separate the depot path
#  from the file path with   has two possible forms - one is an
#  obsolete from that is included to support one customer who was using it:
#
#   Params:
#       multiDepotSpec
#       p4ExcludePaths
#       options - the P4 client options
#       p4Command
#       p4User
#
#   Optional Params:
#       p4Client
#       p4Root
#       checkoutSinglefile
#       opts - so that the debug messages can work properly
#       createFlag - controls whether the client is actually created or not
#
#   Returns:
#       The name of the temporary client spec, if created, or undef on error

#
#   Side Effects
#       Creates a temporary client spec in Perforce
#
#-------------------------------------------------------------------------
sub createP4ClientSpecFromView {
    my $tempP4ClientSpecName = "";
    #bhandley
    # Add the options to the parameter list. This is used to set the client options
    # Add $opts so that debug messaging will work correctly
    # Add createFlag to control whether to actually create the client or just build the client text and return it
    my (  $self,
          $multiDepotSpec,
          $p4ExcludePaths,
          $options,
          $p4Command,
          $p4User,
          $p4Client,
          $p4Root,
          $checkoutSingleFile,
          $opts,
          $createFlag,
          $returnUndefForOneDepotPath  ) = @_;

    $p4Client = undef
        if ( defined($p4Client)
        && $p4Client eq "" );

    $p4Root = undef
        if ( defined($p4Root)
        && $p4Root eq "" );

    # bhandley
    # Default to creating the client if $createFlag is not defined (i.e. not passed in)
    # in order to maintain backward compatibility
    if ( !(defined $createFlag) || ($createFlag eq "") ){
      $createFlag = 1;
    }

    if ( !(defined $returnUndefForOneDepotPath) || $returnUndefForOneDepotPath eq "" ) {
      $returnUndefForOneDepotPath = 0;
    }

    # Bail out if this is not a depot spec at all
    return undef
        if ( !( defined $multiDepotSpec )
        || $multiDepotSpec !~ "^//" );

    # Check for the obsolete format (supported for a particular customer)
    if ( $multiDepotSpec =~ "\.\.\.," ) {

        # NOTE - this format cannot support embedded spaces
        # Translate spaces to new lines, commas to semicolons
        $multiDepotSpec =~ s/\s+/\n/g;
        $multiDepotSpec =~ s/,/;/g;
    }

    # Now check if there is a semicolon
    #return undef if ($multiDepotSpec !~ ";");
    # Bail out if no user given
    if ( !defined($p4User)
        || "$p4User" eq "" )
    {
        $self->issueWarningMsg("*** Error: P4USER required with multi-depot form of client.");
        return "-1";
    }

    # Use the current directory as the  root if none provided.
    my $cwd = getcwd();
    $cwd = $p4Root if ( defined $p4Root );
    my $clientSpecName = "cmdr-client." . $ENV{COMMANDER_JOBSTEPID};
    $clientSpecName = $p4Client if ( defined($p4Client) && $p4Client ne '' );

    #replace whe given client name from the view, with the generated name
    my @lines = split( /\n/, $multiDepotSpec );

    # if this is just one depot path with no target mapping and the caller
    # prefers, return undef.
    if ( $returnUndefForOneDepotPath && scalar(@lines) == 1 && $lines[0] !~ m/\;/g ) {
        return undef;
    }

    my $tmpmultiDepotSpec = '';
    foreach (@lines) {
        if ( $_ =~ m/\/\/.*?\s*\.\.\.\s+\/\/.*?\s*\.\.\./ ) {
            $_ =~ m/\/\/.*\s(\/\/.*?\/)/;
            $_ =~ s/$1/\/\/$clientSpecName\//;
            $tmpmultiDepotSpec .= "$_\n";
        }
        else {
            $tmpmultiDepotSpec .= "$_\n";
        }
    }
    $multiDepotSpec = $tmpmultiDepotSpec
        unless ( $tmpmultiDepotSpec eq '' );

    # bhandley
    # Only open the pipe if $createFlag is 1
    # Pipe data to p4 client
    my $p4ClientCommand = "$p4Command client -i";
    if ($createFlag) {
      if ( defined $ENV{SENTRY_SIMULATE_CREATECLIENT} ) {

          # For testing, redirect to STDERR
          open( OUTPIPE, ">&STDERR" );
          print OUTPIPE "P4 Client Command - $p4ClientCommand\n";
      }
      elsif ( !open( OUTPIPE, "| $p4ClientCommand" ) ) {
          $self->issueWarningMsg("*** Error: Perforce returned ($?) while creating the P4 client.");
          return undef;
      }
    }

    #  Pipe each include line of the spec
    my @viewLines = ();
    my $viewData = "";
    if ( defined($multiDepotSpec) ) {
        print "Creating P4 client named $clientSpecName from explicit view\n" if ($createFlag);
        print "Building client text from explicit view\n" if (!$createFlag);

        $viewData .= "Owner: $p4User\n";
        $viewData .= "Client: $clientSpecName\n";
        $viewData .= "Description: Client created by ElectricCommander.\n";
        $viewData .= "Root: $cwd\n";
        $viewData .= "Options: $options\n";
        $viewData .= "LineEnd:  local\n";
        $viewData .= "View:\n";

        print OUTPIPE $viewData if ($createFlag);
        $self->debugMsg( 1, "*************** Client Spec Data ***************", $opts);

        @viewLines = split( '\n', $multiDepotSpec );
        foreach my $viewLine (@viewLines) {

            #  Form the P4 Client line
            my $clientLine = '';
            if ( $viewLine =~ m/\/\/.*?\s*\.\.\.\s+\/\/.*?\s*\.\.\./ ) {
                $clientLine = $viewLine;
            } else {
                $clientLine = viewLineToClientLine( $viewLine, $clientSpecName, $checkoutSingleFile );
            }

            next if ( $clientLine < 0 );

            # Write the line to the client spec
            print OUTPIPE " $clientLine\n" if ($createFlag);
            $viewData .= " $clientLine\n";
        }

        my $excludes = $self->formatExcludePaths($clientSpecName, $p4ExcludePaths);

        if(length($excludes) && $createFlag) {
            print OUTPIPE $excludes;
            $viewData .= $excludes;
        }

        $self->debugMsg( 1, "$viewData", $opts);
        $self->debugMsg( 1, "*************** End Client Spec Data ***************", $opts);
    }

    close OUTPIPE if ($createFlag);

    if ($?) {
        $self->issueWarningMsg("*** Error: Perforce returned ($?) while creating the P4 client.");
        return "-1";
    }

    return ($clientSpecName, $viewData);
}

#-------------------------------------------------------------------------
#  formatExcludePaths
#
#  Format each exclude line of the spec
#  The lines are defined (by Sentry itself) to have the form
#       depotPath;filePath
#  Example
#       //ABC/master/common/generic/Utils/docs;maintools/docs
#
#   Params:
#       clientSpecName
#       p4ExcludePaths
#
#   Returns:
#       string containing exclude paths
#
#-------------------------------------------------------------------------
sub formatExcludePaths {
    my ($self, $clientSpecName, $p4ExcludePaths) = @_;
    my $ret = "";

    if ( defined $p4ExcludePaths ) {
        my @viewLines = split( '\n', $p4ExcludePaths );
        foreach my $viewLine (@viewLines) {

            #  Form the P4 Client line
            my $clientLine = viewLineToClientLine( $viewLine, $clientSpecName);
            next if ( $clientLine < 0 );

            # Write the line to the client spec
            $ret .= "  -$clientLine\n";
        }
    }

    return $ret;
}


#-------------------------------------------------------------------------
#  viewLineToClientLine
#
#   Convert a "view line" (Sentry format) to a "client line" (P4 format)
#
#   Params:
#       viewLine
#       clientSpecName
#
#   Returns:
#       string containing client line
#       -1 if the format is not valid
#
#-------------------------------------------------------------------------
sub viewLineToClientLine {
    my ($viewLine, $clientSpecName, $checkoutSingleFile) = @_;

    # Split into components on the ';', like
    #       //ABC/master/common/generic/Utils;maintools
    $viewLine =~ s/(^\s+)|(\s+$)//g;
    my ( $depotPath, $filePath ) = split( ";", $viewLine, 2 );
    return -1 if ( !defined $filePath );

    # Clean up the depot path
    #  Add the ... at the end UNLESS, it is already there, OR
    #  the last segment contains a ".", indicating it is a file, not a
    #  directory
    $depotPath =~ s/(^\s+)|(\s+$)//g;
    if ( !$checkoutSingleFile ) {
        $depotPath .= "/..." unless ( $depotPath =~ '\.[^/]*$' || $depotPath =~ '\/\.\.\.$');
    }

    $depotPath = qq{"$depotPath"}
        if ( $depotPath =~ ' ' );

    # Clean up the file path
    $filePath =~ s/(^\s+)|(\s+$)//g;
    if ( !$checkoutSingleFile ) {
        $filePath .= "/..."
            unless ( $filePath =~ '\.[^/]*$' );
    }
    $filePath = "//$clientSpecName/$filePath";
    $filePath = qq{"$filePath"}
        if ( $filePath =~ ' ' );

    # Return the P4 format
    return "$depotPath  $filePath";
}

#-------------------------------------------------------------------------
#  cleanup
#
#  Removes the temporary client, in case of incompleted jobs
#
#   Params:
#       opts
#
#   Returns:
#      nothing
#
#-------------------------------------------------------------------------
sub cleanup {
    my ( $self, $opts ) = @_;

    $self->updateOptions($opts);
    # Load userName and password from the credential
    ( $opts->{P4USER}, $opts->{P4PASSWD} ) =
        $self->retrieveUserCredential( $opts->{credential}, $opts->{P4USER}, $opts->{P4PASSWD} );

    # Set unspecified arguments to undef.
    if ( defined( $opts->{branch} )
        && $opts->{branch} eq "" )
    {
        $opts->{branch} = undef;
    }
    if ( defined( $opts->{template} )
        && $opts->{template} eq "" )
    {
        $opts->{template} = undef;
    }
    if ( defined( $opts->{view} )
        && $opts->{view} eq "" )
    {
        $opts->{view} = undef;
    }
    if ( defined( $opts->{changelist} )
        && $opts->{changelist} eq "" )
    {
        $opts->{changelist} = undef;
    }

    # Delete client unless "retained"
    $self->deleteClient($opts);
}

###############################################################################
# code checkout routines
###############################################################################
####################################################################
# checkoutCode
#
# Checkout code
#
# Args:
#   expected in the $opts hash
#
#   client (the name to be used for the temporary client)
#
#   The following options are MUTUALLY EXCLUSIVE and one of them is required:
#     branch (a branch to insert into our temporary clientspec)
#     template (a clientspec to base our temporary client off of)
#     view (a view of depot to client mappings in the format of depot;client, separated by newlines)
#
#   The following options are optional:
#     dest (the root directory for the temporary clientspec)
#     forcedSync (whether to perform a force sync)
#
# Return:
#    1      = success
#    undef  = failure
####################################################################
sub checkoutCode {
    my ( $self, $opts ) = @_;

    # add configuration that is stored for this config
    my $temporaryClient = 0;
    my $isNewClient     = 0;
    my $ec              = $self->getCmdr();

    if ($opts->{generateChangelog} && !$opts->{updatesFile}) {
        $opts->{updatesFile} = 'Changelog-' . $ENV{COMMANDER_JOBSTEPID};
    }

    # bhandley
    # Add local variable to hold the P4 options string
    my $p4Options       = "";

    # "clean" option was specified, but no dest or dest is just a dot(.).
    if ($opts->{clean} && (!$opts->{dest} || $opts->{dest} =~ m|^\.{1,2}\/?$|s)) {
        print "Warning: Can't perform workspace cleanup if dest parameter is not specified.\n";
        $opts->{clean} = 0;
    }

    #  get the calling step (we are two levels deep in the p4 plugin)
    my $procedureStepIdXpath = $self->getCmdr()->expandString('$[/javascript getProperty(myJobStep.parent.parent, "/myStep/stepId")]');
    my $procedureStepId = $procedureStepIdXpath->findvalue('//value')->value();

    $self->updateOptions($opts);
    $opts->{procedureStepId} = $procedureStepId;

    if (!defined($opts->{smartSync})) {
        $opts->{smartSync} = "0";
    }

    if (!defined($opts->{standardSync})) {
        # If somehow smartSync was set to 1 in our configuration and we didn't
        # define standardSync, define it to 0.  If neither one was defined,
        # default to 1.
        $opts->{standardSync} = ($opts->{smartSync} ? "0" : "1");
    }

    if (!defined($opts->{temp_client})) {
        $opts->{temp_client} = "";
    }

    #set a login flag to avoid authenticating more than once.
    $opts->{loggedIn} = "0";

    my $clientResourceName = '';

    #set the dynamic TEMPLATE-RESOURCENAME


    # Re-write this so use of template (without smartsync) will get template+resource name
    # client exists && !refresh-opt ? use it : create new from template

    # bhandley
    # Move the fetching of the resourceName out of the if statement so that the
    # name is available for all modes
    my $prop         = "/myResource/resourceName";
    my $xpath        = $self->getCmdr()->getProperty($prop);
    my $resourceName = $xpath->findvalue('//value')->value();

    # bhandley
    # print the debug level if it is set to 1 or higher.
    $self->debugMsg( 1, "The debug level is set to: $opts->{debug}", $opts);

    # If we are using a template but don't have a client name yet, create the client name
    if ( $opts->{template} && !$opts->{temp_client} ) {
        # If there's the ec_clientName property is set on the calling step,
        # use its value as the client resource name.  This was added for
        # backwards compatibility with earlier versions that contained this
        # "client" parameter (e.g. 1.1.19).
        # Note: we use 2 expandString calls because that's the only thing that
        # seems to work when testing on both 4.1.0 and 4.2.1.

        my $callingJobStepId = $self->getCmdr()
            ->expandString('$' . '[/javascript myJobStep.parent.parent.jobStepId]')
            ->findvalue("//value")->string_value;
        my ($success, $xpath, $msg) = $self->InvokeCommander(
                {
                    SuppressLog  => 1,
                    IgnoreError => 1
                },
                "expandString",
                '$' . '[/javascript myStep.ec_clientName]',
                {
                    jobStepId => $callingJobStepId
                }
        );
        $clientResourceName = $xpath->findvalue("//value")->string_value;

        if ($clientResourceName ne '') {
            print "Using ec_clientName property set on the calling step: $clientResourceName\n";
        } else {
            print "Using Client Template source ";
            # if smartsync, add the jobstepid to make sure it's unique
            if ( $opts->{smartSync} ) {
                print "with Smart Sync.\n";
                my $jobStepId = $::ENV{COMMANDER_JOBSTEPID};
                $clientResourceName = "$opts->{template}\-$resourceName\-$jobStepId";
                $opts->{temporaryClient} = 1;
            }
            elsif ( $opts->{standardSync} )  {
                # This is for "CI" mode, where the client hangs around
                print "with Standard Sync.\n";
                if ( $opts->{retainTemplateClient} ) {
                    if (!$opts->{dest} )  {
                        print "Error: The 'Destination Directory' option is required when Client Template, Standard Sync, and Retain Client are all enabled. This should be an absolute (not relative) directory path.\n";
                        exit(1);
                    } else {
                        $clientResourceName = "$opts->{template}\-$resourceName";
                    }
                } else {
                    # The client is not going to be retained; embed the job
                    # step id in it to guarantee uniqueness.

                    my $jobStepId = $::ENV{COMMANDER_JOBSTEPID};
                    $clientResourceName = "$opts->{template}\-$resourceName\-$jobStepId";
                    $opts->{temporaryClient} = 1;
                }
            }
            else {
                $self->issueWarningMsg( "*** Error: Either 'Smart Sync' or 'Standard Sync' argument is required.\n" );
                exit(1);
            }

            # If a postfix was specified, append it to the end of the name.
            if (($opts->{postfix}) && ($opts->{postfix} ne "")){
              $clientResourceName .= "\-$opts->{postfix}";
            }
        }
        $opts->{temp_client} = $clientResourceName;
    } elsif ( "$opts->{view}" ne "" && $opts->{standardSync} && $opts->{retainTemplateClient} ){
      # bhandley - new 'mode' in which we'll use an explicit view spec, create a new client,
      # but NOT delete the client, so that it can be reused for incremental syncing
      # In this mode, the user must also provide a unique prefix for the name of the Workspace
      # to create. The Workspace name will be <user entered prefix>-<resourceName>-<user entered postfix>
      # This new mode will also allow the user to select true/false for the standard Perforce workspace
      # options of allwrite, clobber, compress, locked, modtime, rmdir and use these values to create the
      # the new workspace.
      $self->debugMsg( 4, "Using explicit View spec and retaining client", $opts );

      # bhandley - for Prototyping only, set the values of the prefix, postfix and p4Options, etc. These
      # will come from passed parameters once the UI changes are completed
      #$opts->{dontSync}             = 0;
      #$opts->{prefix}               = "BSHTest";
      #$opts->{postfix}              = "123";
      #$opts->{p4Options_allwrite}   = 1;
      #$opts->{p4Options_clobber}    = 1;
      #$opts->{p4Options_compress}   = 1;
      #$opts->{p4Options_locked}     = 0;
      #$opts->{p4Options_modtime}    = 1;
      #$opts->{p4Options_rmdir}      = 1;

      # bhandley
      # Translate the p4Options into text for use in creating a client spec
      $p4Options = ($opts->{allwrite}  ? "allwrite" : "noallwrite") . " " .
                      ($opts->{clobber}   ? "clobber" : "noclobber") . " " .
                      ($opts->{compress}  ? "compress" : "nocompress") . " " .
                      ($opts->{locked}    ? "locked" : "unlocked") . " " .
                      ($opts->{modtime}   ? "modtime" : "nomodtime") . " " .
                      ($opts->{rmdir}     ? "rmdir" : "normdir");

      if (!$opts->{dest} )  {
                print "Error: The 'Destination Directory' option is required when  Standard Sync and Explicit View Spec are enabled. This should be an absolute (not relative) directory path.\n";
                exit(1);
      }
      $clientResourceName = "$opts->{prefix}\-$resourceName";
      if (($opts->{postfix}) && ($opts->{postfix} ne "")){
        $clientResourceName .= "\-$opts->{postfix}";
      }
      $opts->{temp_client} = $clientResourceName;
    }
    else{
      # Explicit View Spec mode, but retainTemplateClient is false
      # Create a unique client name that will be deleted after doing the sync
      if ( !defined $opts->{temp_client}
          || "$opts->{temp_client}" eq ""
          || "$opts->{view}" ne "" )
      {
          my $jobStepId = $::ENV{COMMANDER_JOBSTEPID};
          $opts->{temp_client} = "cmdr-tmp-client-$jobStepId";
          $opts->{temporaryClient} = 1;
          $temporaryClient = 1;
      }
    }

    print "Client name: $opts->{temp_client}\n";

    if ( ( !defined $opts->{apf_running} )
        && $opts->{smartSync} eq "1" )
    {
        if ( $opts->{forcedSync} eq "1" ) {
            print "Error: Forced Sync can't be used with Smart Sync.\n";
            exit(1);
        }
        $self->doSmartSync($opts);
        $self->cleanup($opts);
    }
    elsif ( ( !defined $opts->{apf_running} )
        && $opts->{incremental} eq "1" )
    {
        if ( $opts->{forcedSync} eq "1" ) {
            print "Error: Forced Sync can't be used with Incremental Sync.\n";
            exit(1);
        }
        $self->doIncrementalSync($opts);
        $self->cleanup($opts);
    }
    else {
        if ( defined $opts->{client}
            && $opts->{client} ne "" )
        {
            $self->issueWarningMsg("Warning: client argument is deprecated\n");
        }

        # Load userName and password from the credential
        ( $opts->{P4USER}, $opts->{P4PASSWD} )
            = $self->retrieveUserCredential( $opts->{credential}, $opts->{P4USER}, $opts->{P4PASSWD} );

        # Set unspecified arguments to undef.
        if ( defined( $opts->{branch} )
            && $opts->{branch} eq "" )
        {
            $opts->{branch} = undef;
        }
        if ( defined( $opts->{template} )
            && $opts->{template} eq "" )
        {
            $opts->{template} = undef;
        }
        if ( defined( $opts->{view} )
            && $opts->{view} eq "" )
        {
            $opts->{view} = undef;
        }
        if ( defined( $opts->{changelist} )
            && $opts->{changelist} eq "" )
        {
            $opts->{changelist} = undef;
        }

        # Check for required arguments.
        my $missing    = 0;
        my $clientSpec = undef;

        if ( $opts->{dest} =~ /[\w]\:/
            && length $opts->{dest} == 2 )
        {
            $opts->{dest} .= q{\\};
        }
        else {
            $opts->{dest} = File::Spec->rel2abs( $opts->{dest} );
        }

        # Create a temporary Perforce client that we can use to extract
        # the snapshot and compute a change list.
        my $HostName = hostname;
        $self->debugMsg(6, "Agent hostname: $HostName, resource name: $resourceName", $opts);

        # Check if its an existing client.
        my ( $p4Command, $passwordStart, $passwordLength ) = $self->setupP4($opts);
        my $clientOutput = $self->clientExists($p4Command, $opts->{temp_client});

        #The client doesn't exist, so create a new client.
        if ( !$clientOutput )
        {
            $isNewClient = 1;
            if (   !defined( $opts->{branch} )
                && !defined( $opts->{template} )
                && !defined( $opts->{view} )
                && !defined( $opts->{stream} ) )
            {
            $self->issueWarningMsg( "Error: Exactly one of branch/template/view/stream " . "arguments is required\n" );
                exit(1);
            }
            elsif ( defined( $opts->{template} )
                && "$opts->{template}" ne "" )
            {
                # Take the template client's spec and replace in the root, host, owner,
                # and client name.
                ##################################
                # NOTE: I'm duplicating this below. It sucks but I'm in a hurry. Refactor all this out including the createP4Client*() stuff.
                ##################################
                my $base = $self->RunCommand(
                    "$p4Command client -o -t $opts->{template} $opts->{template}",
                    {   LogCommand     => 1,
                        HidePassword   => 1,
                        passwordStart  => $passwordStart,
                        passwordLength => $passwordLength
                    }
                );
                if ( !defined $base ) {
                    exit(1);
                }
                $clientSpec = "\n" . $base;
                $clientSpec =~ s/\nRoot[^\n]*\n/\nRoot: $opts->{dest}\n/;

                # if P4USER given (even if blank) use it, otherwise keep the one in the template
                if ( defined( $opts->{P4USER} ) ) {
                    $clientSpec =~ s/\nOwner[^\n]*\n/\nOwner: $opts->{P4USER}\n/;
                }
                $clientSpec =~ s/\nHost[^\n]*\n/\nHost: $HostName\n/;
                $clientSpec =~ s/\nClient[^\n]*\n/\nClient: $opts->{temp_client}\n/;
                $clientSpec =~ s/\/\/$opts->{template}\//\/\/$opts->{temp_client}\//g;
            }
            elsif ( defined( $opts->{branch} )
                && "$opts->{branch}" ne "" )
            {

                # we need to make a client
                $clientSpec
                    = "Client: $opts->{temp_client}\n"
                    . "Owner: $opts->{P4USER}\n"
                    . "Description: Temporary client created by ElectricSentry.\n"
                    . "Root: $opts->{dest}\n"
                    . "LineEnd: unix\n"
                    . "View: $opts->{branch}/... //$opts->{temp_client}/...\n";
            }
            if ( defined $clientSpec ) {
                my $output = $self->createP4ClientSpec( $p4Command, $passwordStart, $passwordLength, $clientSpec );
                if ( !defined $output ) {
                    $self->issueWarningMsg("Error: Was not able to generate clientspec from template or branch.\n");
                    exit(1);
                }
            }
            elsif ( defined( $opts->{view} )
                && "$opts->{view}" ne "" )
            {
                #bhandley
                # Add the p4Options text to the call to create the client.
                my ($p4ClientName, $clientText)
                                = $self->createP4ClientSpecFromView( $opts->{view}, undef, $p4Options, $p4Command, "$opts->{P4USER}",
                    "$opts->{temp_client}", "$opts->{dest}", "$opts->{checkoutSingleFile}", $opts );
                if ( !( defined $p4ClientName )
                    || $p4ClientName eq "-1" )
                {
                    $self->issueWarningMsg("Error: Was not able to generate clientspec from view.\n");
                    exit(1);
                }
            }
            elsif ( defined( $opts->{stream} )
                && $opts->{stream} ne '' )
            {
                print "Temp client: $opts->{temp_client}\n";
                my $output = $self->createP4ClientFromStream(
                    $p4Command,      $passwordStart,       $passwordLength,
                    $opts->{stream}, $opts->{temp_client}, $opts->{dest}
                );
                if ( !defined $output ) {
                    $self->issueWarningMsg("Error: Was not able to generate client from stream.\n");
                    exit(1);
                }
            }
            else {
                $self->issueWarningMsg( "Error: Was not able to generate clientspec; exactly one of "
                        . "branch/template/view/stream arguments is required\n" );
                exit(1);
            }
        }
        else {
            # The client exists, but if we're using a template or an explicit view we will "refresh" it from
            # the original template and use it
            # TODO: This chunk of code is duplicated in three places -- it desperately needs to be refactored
            # bhandley
            # Also do this for the explicit view mode, but use the current, passed parameters as the source of the new info

            my $p4ClientName = "";

            if (( $opts->{template} ) || ( $opts->{view} )) {
              print "Using retained client $opts->{temp_client} derived from template $opts->{template}\n" if $opts->{template};
              print "Using retained client $opts->{temp_client} created from explicit view\n" if $opts->{view};

              # bhandley
              # If using an explicit view, build the client text
              if ($opts->{view}){
                ($p4ClientName, $clientSpec)
                                  = $self->createP4ClientSpecFromView( $opts->{view}, undef, $p4Options, $p4Command, "$opts->{P4USER}",
                      "$opts->{temp_client}", "$opts->{dest}", "$opts->{checkoutSingleFile}", $opts, 0 );
                $self->debugMsg(1, "Refreshing $p4ClientName with client data:\n$clientSpec", $opts);
              } else {

                  # Take the template client's spec and replace in the root, host, owner,
                  # and client name.
                  my $base = $self->RunCommand(
                      "$p4Command client -o -t $opts->{template} $opts->{template}",
                      {
                          LogCommand     => 1,
                          LogResult      => 0,
                          HidePassword   => 1,
                          passwordStart  => $passwordStart,
                          passwordLength => $passwordLength
                      }
                  );

                  if ( $opts->{dest} =~ /[\w]\:/
                      && length $opts->{dest} == 2 )
                  {
                      $opts->{dest} .= q{\\};
                  }
                  else {
                      $opts->{dest} = File::Spec->rel2abs( $opts->{dest} );
                  }
                  if ( !defined $base ) {
                      exit(1);
                  }

                $self->debugMsg(6, "Client data from template:\n$base", $opts);

                  $clientSpec = "\n" . $base;
                  $clientSpec =~ s/\nRoot[^\n]*\n/\nRoot: $opts->{dest}\n/;

                  # if P4USER given (even if blank) use it, otherwise keep the one in the template
                  if ( defined( $opts->{P4USER} ) ) {
                      $clientSpec =~ s/\nOwner[^\n]*\n/\nOwner: $opts->{P4USER}\n/;
                  }

                  $clientSpec =~ s/\nHost[^\n]*\n/\nHost: $HostName\n/;
                  $clientSpec =~ s/\nClient[^\n]*\n/\nClient: $opts->{temp_client}\n/;
                  $clientSpec =~ s/\/\/$opts->{template}\//\/\/$opts->{temp_client}\//g;
                }

                $self->debugMsg(1, "Refreshing $opts->{temp_client} with client data:\n$clientSpec", $opts);

                # Push the refreshed spec into the existing client: pipe data to p4 client
                my $cmdout = $self->RunCommand(
                    "$p4Command client -i",
                    {
                        LogCommand     => 1,
                        LogResult      => 1,
                        HidePassword   => 1,
                        passwordStart  => $passwordStart,
                        passwordLength => $passwordLength,
                        input          => $clientSpec
                    }
                );
            }
            else {
                # It's not a template but the client exists
                $self->issueWarningMsg("Error: The client $opts->{temp_client} already exists.\n");
                exit(1);
            }
          }

        # Find the change number to which to sync.
        my $changeNumber;
        if ( defined( $opts->{changelist} ) ) {
            if ( defined( $opts->{template} )
                && $opts->{changelist} eq "have" )
            {
                $changeNumber = $opts->{template};
            }
            else {
                $changeNumber = $opts->{changelist};
            }
        }
        else {
            # Extract the number of the most recent changelist.
            ($changeNumber) = $self->getP4LastSnapshotId($opts);
        }

        my $scmKey = $self->getKeyFromTemplate( $opts->{template} || $opts->{temp_client}, defined($opts->{temporaryClient})?$opts->{procedureStepId}:0 );
        my $start = "";
        if ( length($opts->{lastSnapshot}) )
        {
            # use the lastSnapshot that was passed in.
            # note: don't include
            # the change given by $::gLastSnapshot, since that was already
            # included in the previous build.
            $start = $opts->{lastSnapshot};
        } elsif (($opts->{changelist}) && ($opts->{changelist} ne "")) {
            $start = $opts->{changelist};
        } else {
            $start = $self->getStartForChangeLog($scmKey);
        }

        if ( $start eq "" ) {
            $start = $changeNumber;
        }

        # bhandley
        # Handle the new clean flag.
        # Remove all files and dirs under the destination dir
        if ($opts->{clean}){
            print "Cleaning workspace destination: $opts->{dest}\n";

            # Set the 'force' flag to force a full sync after doing the clean
            $opts->{forcedSync} = 1;

            # Remove all files and dirs under the root of the workspace
            my $debugLevel = $opts->{debug};
            my $verbose = 0;
            if ($debugLevel > 1){ $verbose = 1;}
            print "verbose is set to $verbose based on debug level\n";

            File::Path::rmtree( "$opts->{dest}", $verbose, {keep_root => 1} );
        }

        # bhandley
        # Handle the new reportOnly flag. This can be used to not actually sync.
        # All of the change reporting is still done, but the sync itself is skipped
        if (!$opts->{reportOnly}){
          # Retrieve files.
          # Determine whether we should perform a force sync or not (by default, force sync is set to false)
          my ($forcedSync, $syncHaveList, $parallelSync) = ("", "", "");
          if ( "$opts->{forcedSync}" eq "1" ) {
              $forcedSync = "-f ";
          } elsif( $opts->{retainTemplateClient} ne "1" ) {
              # When we don't need to keep client template,
              # enable bypassing of 'have list' updates, thus speeding up sync
              $syncHaveList = "-p ";
          }

          if(length($opts->{parallelSync})) {
              $parallelSync = "--parallel=$opts->{parallelSync}";
          }

          my $tmp_cmd   = "$p4Command  -c $opts->{temp_client} sync $parallelSync $forcedSync $syncHaveList \@$changeNumber";
          my $enableLog = 0;
          if ( $opts->{debug} eq "6" ) {
              $tmp_cmd   = "$p4Command -Ztrack=1 -c $opts->{temp_client} sync $parallelSync $forcedSync $syncHaveList \@$changeNumber";
              $enableLog = 1;
          }
          my $result = $self->RunCommand(
              $tmp_cmd,
              {   LogCommand     => 1,
                  HidePassword   => 1,
                  LogResult      => $enableLog,
                  passwordStart  => $passwordStart,
                  passwordLength => $passwordLength
              }
          );
          if ( !defined $result ) {
              $self->issueWarningMsg("Error: Sync to client failed.\n");
              $self->cleanup($opts);
              exit(1);
          }

          # bhandley
          # Handle the new unshelving feature.
          # Note that we only unshelve if we are actually syncing
          # No sync implies no unshelving.
          # The list of CLs to unshelve is given,
          # in order, in $opts->{unshelveCLs}, one CL per line
          if (($opts->{unshelveCLs}) && $opts->{unshelveCLs} ne ""){
            my @unshelveCLs = split /\n/, $opts->{unshelveCLs};
            $self->debugMsg( 4, "The list of CLs to unshelve is: @unshelveCLs", $opts );
            foreach my $cl (@unshelveCLs){
              $self->debugMsg( 4, "unshelving $cl to workspace", $opts );
              my $result = $self->RunCommand(
                "$p4Command -c $opts->{temp_client} unshelve -s $cl -f",
                {   LogCommand     => 1,
                    HidePassword   => 1,
                    LogResult      => $enableLog,
                    passwordStart  => $passwordStart,
                    passwordLength => $passwordLength
                }
              );
              if ( !defined $result ) {
                $self->cleanup($opts);
                die("Unshelve failed.");
              }

              $result = $self->RunCommand(
                "$p4Command -c $opts->{temp_client} revert -k //$opts->{temp_client}/...",
                {   LogCommand     => 1,
                    HidePassword   => 1,
                    LogResult      => $enableLog,
                    passwordStart  => $passwordStart,
                    passwordLength => $passwordLength
                });
              if ( !defined $result ) {
                $self->cleanup($opts);
                die("Revert failed.");
              }
            }
          }
        } else {
          print "Skipping sync because the \"reportOnly\" flag is set\n";
        }

        # A perforce label is a valid input parameter
        # We need to convert it into a changelist number for ease of changelog generation
        $changeNumber = $self->resolveLabel($opts, $changeNumber);
        $start = $self->resolveLabel($opts, $start);

        $start += 1 if $start != $changeNumber;
        $self->generateChangelog($opts, $scmKey, $start, $changeNumber);

        # bhandley
        # Write out the clientname used for this sync to properties
        # on the job. Some customers use thse settings to issue additional p4 commands
        # in subsequent steps.
        $self->getCmdr()->setProperty( "/myJob/P4CLIENT", $opts->{temp_client} );

        if ( !defined $opts->{apf_running} ) {
            $self->cleanup($opts);
        }

        return $changeNumber;
    }

    #log out
    if($opts->{autoLogin} && $opts->{autoLogin} eq "1"){
        $self->p4Logout($opts);
    }
}

sub p4Login{
    my ( $self, $opts) = @_;
    if($opts->{loggedIn} eq "0"){
        my $login_cmd = "p4 login";
        my $password = $opts->{P4PASSWD};
        open FILE, "| $login_cmd" or die "Can't pipe p4";
        print FILE $password;
        close FILE;
        $opts->{loggedIn} = "1";
    }
}

sub p4Logout{
    my ( $self, $opts) = @_;
    my $logout_cmd = "p4 logout";
    $self->RunCommand("$logout_cmd", {LogCommand => 1});
    $opts->{loggedIn} = "0";
}

####################################################################
# getKeyFromTemplate
#
# Side Effects:
#
# Arguments:
#   template  -   the name of the perforce client being used as a template
#
# Returns:
#   "Perforce" prepended to the template
####################################################################
sub getKeyFromTemplate {
    my ( $self, $template, $procedureStepId ) = @_;
    if($procedureStepId>0) {
        return "Perforce-procedureStepId-$procedureStepId";
    } else {
        return "Perforce-$template";
    }
}


####################################################################
# resolveLabel - resolve label name to changelist number
#
# Arguments:
#      opts -         options hash
#      cl -           label or changelist number
#
# Returns:
#   Changelist number
####################################################################
sub resolveLabel {
    my ( $self, $opts, $cl ) = @_;

    $self->RunCommand(
        "$self->{p4Command} -c $opts->{temp_client} changes -s submitted -m1 \@$cl",
        {
            LogCommand     => 1,
            HidePassword   => 1,
            passwordStart  => $self->{passwordStart},
            passwordLength => $self->{passwordLength}
        }) =~ /^Change ([\d]+)/;

    return $1;
}


#-------------------------------------------------------------------------
# generateChangelog
#
#      Given a list of Perforce changes, create a file describing the
#      corresponding updates in more detail. Also, update properties on job and schedule.
#
# Results:
#      changelog - string containing generated changelog.
#
# Side Effects:
#      A file is written containing one section for each line in
#      $changes.  This section contains the name of the user making
#      the change, and the details for the change provided by Perforce.
#
# Arguments:
#      opts -         options hash
#      scmKey -       SCM key
#      start -        start change number
#      changeNumber - end change number
#-------------------------------------------------------------------------
sub generateChangelog {
    my ( $self, $opts, $scmKey, $start, $changeNumber ) = @_;
    my $ec = $self->getCmdr();

    print "Creating changelog, start change: $start, end change: $changeNumber.\n";

    #Set additional, easier-to-use properties on the Job and Schedule
    $ec->setProperty( "/myJob/lastGoodSnapshot", $changeNumber );

    my ( $projectName, $scheduleName ) = $self->GetProjectAndScheduleNames();
    my $schedPrefix = undef;

    if (length($scheduleName)) {
        $schedPrefix = "/projects[$projectName]/schedules[$scheduleName]";

        # Store the current CL number in lastGoodSnapshot on the Schedule
        $ec->setProperty( "$schedPrefix/lastGoodSnapshot", $changeNumber );
    }

    return "" if(!$opts->{generateChangelog} && !length($opts->{updatesFile}));

    my $changes_cmd = "$self->{p4Command} -c $opts->{temp_client} -ztag changes //$opts->{temp_client}/...\@$start,$changeNumber";
    open(my $changes_handle, "-|", $changes_cmd) || die "Error: can't open p4 changes pipe: $!.";

    my ($changes, $updates_file, $updates_handle, $updates) = ("", $opts->{updatesFile}, undef, "");
    my ($current_user, $change_count, $change_number) = (undef, 0, undef);
    my %users = ();

    if(length($updates_file)) {
        print "Writing update log to $updates_file file\n";
        open($updates_handle, ">", $updates_file) || die "Error: can't open updates file: $!";
    }

    while(<$changes_handle>) {
        my ($key, $value) = (split)[1..2];

        if($key eq "change") {
            $change_count++;
            $change_number = $value;
        } elsif($key eq "user") {
            $users{$value} = 1;

            my $out = $self->RunCommand(
                "$self->{p4Command} -c $opts->{temp_client} describe -s $change_number",
                {
                    LogCommand     => 1,
                    HidePassword   => 1,
                    passwordStart  => $self->{passwordStart},
                    passwordLength => $self->{passwordLength}
                });

            $changes .= $out if $opts->{generateChangelog};

            if($updates_handle) {
                if($current_user ne $value) {
                    my $header = '-' x  25 . " $value " . '-' x  25 . "\n\n";

                    $current_user = $value;
                    print ($updates_handle $header);
                    $updates .= $header;
                }

                print ($updates_handle $out);
                $updates .= $out;
            }
        }
    }

    if($updates_handle) {
        # write the p4Updates property
        $ec->setProperty("/myJob/p4Updates", $updates);
        close($updates_handle);
    }

    $self->setPropertiesOnJob($scmKey, $changeNumber, $changes);
    $self->updateLastGoodAndLastCompleted($opts);

    if($opts->{generateChangelog}) {
        if (length($scheduleName)) {
            $ec->setProperty("$schedPrefix/ecscm_changelogs/$scmKey", $changes);
        }

        $self->createLinkToChangelogReport("Changelog Report");
    }

    close($changes_handle);

    my $user_count = keys %users;
    my @users = ();
    foreach my $user (keys %users) {
        push(@users, $user);
    }

    # Set the 'users' property to the list of users who made changes
    $ec->setProperty("/myJob/users","@users");

    if ($change_count) {
      $ec->setProperty("postSummary", "$change_count changes by $user_count users: @users");
      $ec->setProperty("/myJob/p4Summary","$change_count changes by $user_count users: @users");
    } else {
      $ec->setProperty("postSummary","No changes");
      $ec->setProperty("/myJob/p4Summary","No changes");
    }

    return $changes;
}


#-------------------------------------------------------------------------
# resetPermissions
#
#      Sets the permissions of all the files in the source directory
#      to read only.
#
# Results:
#      None.
#
#
# Arguments:
#
#     $opts
#-------------------------------------------------------------------------
sub resetPermissions {
    my $mode = (lstat($_))->mode & 07777;

    # Apply write permissions removal mask to current file mode
    my $newmode = sprintf('%04o', $mode & ~(00222));
    -f _ && chmod( oct($newmode), $_ );
}

#-------------------------------------------------------------------------
# clientExists
#
#      Determines if a clients exists or not
#
# Results:
#      p4 client output, or undef if client does not exists.
#
#
# Arguments:
#
#     $opts
#-------------------------------------------------------------------------
sub clientExists {
    my ( $self, $p4Command, $client ) = @_;

    my $clientOutput = $self->RunCommand(
        "$p4Command clients -e \"$client\"",
        {   LogCommand     => 0,
            LogResult      => 0 }
    );

    if($clientOutput eq '') {
        undef($clientOutput);
    }

    return $clientOutput;
}

#-------------------------------------------------------------------------
# syncChangedOrMissingFiles
#
#      Force sync for the changed or missed files in the workspace
#
# Results:
#      None.
#
#
# Arguments:
#
#     $opts
#-------------------------------------------------------------------------
sub syncChangedOrMissingFiles {
    my ( $self, $opts, $changeNumber ) = @_;
    my ( $p4Command, $passwordStart, $passwordLength ) = $self->setupP4($opts);
    my $here = cwd();
    my $logResult;
    my $logCommand;

    $self->updateOptions($opts);
    ( $logResult, $logCommand ) = $self->lvlForCommands($opts);
    $self->debugMsg( 4, "Getting the diff $opts->{temp_client} ", $opts );

    #get the missing and different files
    my $result = $self->RunCommand(
        "$p4Command -c $opts->{temp_client} diff -se -t \@$changeNumber",
        {   LogCommand     => $logCommand,
            LogResult      => $logResult,
            HidePassword   => 1,
            passwordStart  => $passwordStart,
            passwordLength => $passwordLength
        }
    );
    $result .= $self->RunCommand(
        "$p4Command -c $opts->{temp_client} diff -sd -t \@$changeNumber",
        {   LogCommand     => $logCommand,
            LogResult      => $logResult,
            HidePassword   => 1,
            passwordStart  => $passwordStart,
            passwordLength => $passwordLength
        }
    );
    my @lines = split( /\n/, $result );
    my $result_tmp;
    foreach (@lines) {
        my $row = $_;
        if ( $row ne "" ) {
            $row = $self->ASCIIExpansion($row);
            $result_tmp .= "$row\n";
        }
    }
    $result = $result_tmp;
    # Create a temporary file for incremental_adds
    my $incrementalTmpFile = File::Temp->new( TEMPLATE => 'incremental_adds_XXXXX',
                                              DIR => $here);

    if ( $result ne q{} ) {
        chomp($result);
        print( $incrementalTmpFile $result );
    }
    if ( $result ne q{} ) {
        my $versionChecked = 0;
        if ( $self->getP4Version($opts) >= 20111 ) {
            $versionChecked = 1;
        }
        my $filenum = 0;
        my $bparam  = '';
        if ($versionChecked) {
            $filenum = $self->countFileLines("$incrementalTmpFile");
            $bparam  = "-b $filenum ";
        }
        $self->debugMsg( 4, "Forced sync on the missing or diff files: \n******\n\n$result\n*******\n\n ", $opts );
        my $tmp_cmd   = "$p4Command -c $opts->{temp_client} $bparam-x \"$incrementalTmpFile\" sync -f \@$changeNumber";
        my $enableLog = $logResult;
        if ( $opts->{debug} eq "6" ) {
            $tmp_cmd   = "$p4Command -Ztrack=1 -c $opts->{temp_client} $bparam-x \"$incrementalTmpFile\" sync -f \@$changeNumber";
            $enableLog = 1;
        }
        my $output = $self->RunCommand(
            $tmp_cmd,
            {   LogCommand     => $logCommand,
                LogResult      => $enableLog,
                HidePassword   => 1,
                passwordStart  => $passwordStart,
                passwordLength => $passwordLength
            }
        );
    }
}

#-------------------------------------------------------------------------
# doIncrementalSync
#
#      This method is used for reverting the changes over an existing
#      client, synchronize it and prepare it for the preflight.
#
# Results:
#      None.
#
# Side Effects:
#      A file is written containing one section for each line in
#      $changes.  This section contains the name of the user making
#      the change, and the details for the change provided by Perforce.
#
# Arguments:
#      p4Command -     The root p4 command
#      changes -       Output from "p4 changes", listing one change number
#                      on each line.
#      fileName -      Name of file in which to write the details.
#-------------------------------------------------------------------------
sub doIncrementalSync {
    my ( $self, $opts ) = @_;
    print "\n\nPerforming Incremental Sync.\n\n";

    $self->updateOptions($opts);
    # Load userName and password from the credential
    ( $opts->{P4USER}, $opts->{P4PASSWD} )
        = $self->retrieveUserCredential( $opts->{credential}, $opts->{P4USER}, $opts->{P4PASSWD} );

    my $client = $opts->{permanent_client};
    my ( $p4Command, $passwordStart, $passwordLength ) = $self->setupP4($opts);
    my $clientOutput = $self->clientExists($p4Command, $client);
    $clientOutput or die("Permanent client \"$client\" does not exists.");

    $clientOutput =~ /root\s([^']+)/;
    my $root = $1;
    chop($root);

    if(length($opts->{dest}) > 0 && $opts->{dest} ne $root) {
        die("Destination directory must match client's root directory.");
    } else {
        $opts->{dest} = $root;
    }

    # Reconcile workspace, finding any added or deleted files
    $clientOutput = $self->RunCommand(
        "$p4Command -c \"$client\" reconcile -ad //...",
        {   LogCommand     => 1,
            LogResult      => 1,
            HidePassword   => 1,
            IgnoreError    => 1,
            passwordStart  => $passwordStart,
            passwordLength => $passwordLength
        }
    );

    # Do revert again, to restore workspace
    $clientOutput = $self->RunCommand(
        "$p4Command -c \"$client\" revert //...",
        {   LogCommand     => 1,
            LogResult      => 1,
            HidePassword   => 1,
            IgnoreError    => 1,
            passwordStart  => $passwordStart,
            passwordLength => $passwordLength
        }
    );

    #Open for edit files copied by the client.
    open( DELTAS, "ecpreflight_data/deltas" )
        or $self->error("Cannot open ecpreflight_data/deltas: $!.");
    while (<DELTAS>) {
        my $fileName = $_;
        print "$_\n";
        chomp($fileName);
        my $targetFile = "//$client/$fileName";
        $self->RunCommand(
            qq{$p4Command -c "$client" edit "$targetFile"},
            {   LogCommand     => 1,
                HidePassword   => 1,
                passwordStart  => $passwordStart,
                passwordLength => $passwordLength
            }
        );
    }
    close(DELTAS);

    #Delete files
    open( DELETES, "ecpreflight_data/deletes" )
        or $self->error("Cannot open ecpreflight_data/deletes: $!.");
    while (<DELETES>) {
        my $fileName = $_;
        print "$_\n";
        chomp($fileName);
        my $targetFile = "//$client/$fileName";
        $self->RunCommand(
            qq{$p4Command -c "$client" delete "$targetFile"},
            {   LogCommand     => 1,
                HidePassword   => 1,
                passwordStart  => $passwordStart,
                passwordLength => $passwordLength
            }
        );
    }
    close(DELETES);
}
####################################################################
# listFiles
#
#      used with Find, will create a file with all the files in the source
#
# Results:
#      A file in workspace folder containing the path of all the files
#
#
# Arguments:
#
#     $output_fh - file handle for the output file
#     $file - file to work on
####################################################################
sub listFiles {
    my ( $output_fh, $file ) = @_;
    my ( $dev, $ino, $mode, $nlink, $uid, $gid ) = lstat($file);

    # from perl man http://perldoc.perl.org/File/Find.html
    # the _ is a magical filehandle that caches the information
    # from the preceding lstat
    -f _
        && print( $output_fh qq{$File::Find::name\n} );
}
####################################################################
# deleteUntrackedFiles
#
#      used with Find, will create a file with all the files in the source
#      that are not present in the depot.
#
# Results:
#      A file in ecpreflight_data folder containing the path of all the files
#
#
# Arguments:
#
#     $opts
####################################################################
sub deleteUntrackedFiles {
    my ( $self, $opts ) = @_;
    my ( $p4Command, $passwordStart, $passwordLength ) = $self->setupP4($opts);
    my $here = cwd();
    my $logResult;
    my $logCommand;

    $self->updateOptions($opts);
    ( $logResult, $logCommand ) = $self->lvlForCommands($opts);

    my $listFilesTempFile = File::Temp->new( TEMPLATE => 'listfiles_XXXXX',
                                                  DIR => $here);
    # Find all the files in the destination directory and add them to the
    # temporary output file
    find(
      sub {
       listFiles($listFilesTempFile, $_);
     },
      $opts->{dest}
   );

    my $versionChecked = 0;
    if ( $self->getP4Version($opts) >= 20111 ) {
        $versionChecked = 1;
    }
    my $filenum = 0;
    my $bparam  = '';
    if ($versionChecked) {
        $filenum = $self->countFileLines("$listFilesTempFile");
        $bparam  = "-b $filenum ";
    }
    my $output = $self->RunCommand(
        "$p4Command -s -c $opts->{temp_client} $bparam-x \"$listFilesTempFile\" have",
        {   LogCommand     => $logCommand,
            LogResult      => 0,
            HidePassword   => 1,
            IgnoreError    => 1,
            passwordStart  => $passwordStart,
            passwordLength => $passwordLength
        }
    );
    if ($output) {
        $output =~ s/exit\:\s0\n//ixmg;
    }
    my @lines = split /\n/, $output;
    $self->debugMsg( 2, "Deleting files that are not present in the depot", $opts );
    my $deleteCount = 0;

    # Delete all the files
    # sample output:
    # error: /vagrant/smartSyncTest/Talkhouse/shouldBeDeleted - file(s) not on client.
    foreach (@lines) {
        if ( $_ =~ m/error:\s(.*)\s\-\sfile\(s\)\snot\son\sclient\./ ) {
            $self->debugMsg( 3, "Deleting: $1", $opts );
            my $filename = $1;
            chomp($filename);
            chmod( 0777, $filename );
            unlink($filename)
                or print "Could not delete $filename: $!";
            $deleteCount++;
        }
    }
    if ( $deleteCount == 0 ) {
        $self->debugMsg( 2, "   No files deleted.", $opts );
    }
    else {
        $self->debugMsg( 2, "   $deleteCount file(s) deleted.", $opts );
    }

}
####################################################################
# getClientName
#
#      Return the dynamic client name, if client is undef or empty, will use
#      the template name and the resource to generate the name.
#      If the client name exists, it will just by pass it.
#
# Results:
#      A string containing the client name
#
# Arguments:
#
#     $name
####################################################################
sub getClientName {
    my ( $self, $opts ) = @_;
    my $clientResourceName = '';

    #set the dynamic TEMPLATE-RESOURCENAME
    if ( !defined $opts->{temp_client}
        || $opts->{temp_client} eq q{} )
    {
        my $prop         = "/myResource/resourceName";
        my $xpath        = $self->getCmdr()->getProperty($prop);
        my $resourceName = $xpath->findvalue('//value')->value();
        $clientResourceName = "$opts->{template}\-$resourceName";
        return $clientResourceName;
    }
    else {
        return $opts->{temp_client};
    }
}

####################################################################
# createClient
#
#      Creates a client using, a template, a view or a branch
#
# Results:
#
#
# Arguments:
#
#     $opts
####################################################################
sub createClient {
    my ( $self, $opts ) = @_;
    my $clientSpec = undef;
    my $HostName   = hostname;
    my ( $p4Command, $passwordStart, $passwordLength ) = $self->setupP4($opts);
    my $logResult;
    my $logCommand;

    $self->updateOptions($opts);
    ( $logResult, $logCommand ) = $self->lvlForCommands($opts);
    if (   !defined( $opts->{branch} )
        && !defined( $opts->{template} )
        && !defined( $opts->{view} )
        && !defined( $opts->{stream} ) )
    {
        $self->issueWarningMsg( "Error: Exactly one of branch/template/view/stream " . "arguments is required\n" );
        exit(1);
    }

    # ------------------------------------------------------------------------ Template
    elsif ( defined( $opts->{template} )
        && "$opts->{template}" ne "" )
    {
        # Take the template client's spec and replace in the root, host, owner,
        # and client name.
        my $base = $self->RunCommand(
            "$p4Command client -o -t $opts->{template} $opts->{template}",
            {   LogCommand     => $logCommand,
                LogResult      => $logResult,
                HidePassword   => 1,
                passwordStart  => $passwordStart,
                passwordLength => $passwordLength
            }
        );

        if ( $opts->{dest} =~ /[\w]\:/
            && length $opts->{dest} == 2 )
        {
            $opts->{dest} .= q{\\};
        }
        else {
            $opts->{dest} = File::Spec->rel2abs( $opts->{dest} );
        }
        if ( !defined $base ) {
            exit(1);
        }
        $clientSpec = "\n" . $base;
        $clientSpec =~ s/\nRoot[^\n]*\n/\nRoot: $opts->{dest}\n/;

        # if P4USER given (even if blank) use it, otherwise keep the one in the template
        if ( defined( $opts->{P4USER} ) ) {
            $clientSpec =~ s/\nOwner[^\n]*\n/\nOwner: $opts->{P4USER}\n/;
        }
        $clientSpec =~ s/\nHost[^\n]*\n/\nHost: $HostName\n/;
        $clientSpec =~ s/\nClient[^\n]*\n/\nClient: $opts->{temp_client}\n/;
        $clientSpec =~ s/\/\/$opts->{template}\//\/\/$opts->{temp_client}\//g;
    }
    elsif ( defined( $opts->{branch} )
        && "$opts->{branch}" ne "" )
    {
        # we need to make a client
        $clientSpec
            = "Client: $opts->{temp_client}\n"
            . "Owner: $opts->{P4USER}\n"
            . "Description: Temporary client created by ElectricSentry.\n"
            . "Root: $opts->{dest}\n"
            . "LineEnd: unix\n"
            . "View: $opts->{branch}/... //$opts->{temp_client}/...\n";
    }
    if ( defined $clientSpec ) {
        $self->debugMsg( 2, "client spec: $clientSpec", $opts );
        my $output = $self->createP4ClientSpec( $p4Command, $passwordStart, $passwordLength, $clientSpec );
        if ( !defined $output ) {
            $self->issueWarningMsg("Error: Was not able to generate clientspec from template or branch.\n");
            exit(1);
        }
    }
    elsif ( defined( $opts->{view} )
        && "$opts->{view}" ne "" )
    {
        if ( $opts->{dest} =~ /[\w]\:/
            && length $opts->{dest} == 2 )
        {
            $opts->{dest} .= q{\\};
        }
        else {
            $opts->{dest} = File::Spec->rel2abs( $opts->{dest} );
        }

        my $p4ClientName = $self->createP4ClientSpecFromView( $opts->{view}, undef, "", $p4Command, $opts->{P4USER},
            $opts->{temp_client}, $opts->{dest}, "$opts->{checkoutSingleFile}", $opts );

        if ( !( defined $p4ClientName )
            || $p4ClientName eq "-1" )
        {
            $self->issueWarningMsg("Error: Was not able to generate clientspec from view.\n");
            exit(1);
        }
    }
    elsif ( defined( $opts->{stream} )
        && $opts->{stream} ne '' )
    {
        my $output = $self->createP4ClientFromStream( $p4Command, $passwordStart, $passwordLength, $opts->{stream},
            $opts->{temp_client}, $opts->{dest} );
        if ( !defined $output ) {
            $self->issueWarningMsg("Error: Was not able to generate client from stream.\n");
            exit(1);
        }
    }
    else {
        $self->issueWarningMsg( "Error: Was not able to generate clientspec; exactly one of "
                . "branch/template/view/stream arguments is required\n" );
        exit(1);
    }
}

#-------------------------------------------------------------------------
# deleteClient
#
#      Deletes a client using the name defined in $opts
#
# Results:
#      -
#
# Arguments:
#
#     $opts
#-------------------------------------------------------------------------
sub deleteClient {
    my ( $self, $opts ) = @_;
    my $logResult;
    my $logCommand;

    $self->updateOptions($opts);
    ( $logResult, $logCommand ) = $self->lvlForCommands($opts);
    my ( $p4Command, $passwordStart, $passwordLength ) = $self->setupP4($opts);
    if ( defined $opts->{temp_client} && $opts->{temp_client} ne "" ) {
        if ( $self->clientExists($p4Command, $opts->{temp_client}) ) {
            # Only keep the client in "CI" mode: Retain Template and Standard Sync options
            if ( $opts->{retainTemplateClient} && $opts->{standardSync} ) {
                print "Retaining client $opts->{temp_client} as requested.\n";
            }
            else {
                print "Deleting temporary client $opts->{temp_client}.\n";
                # Delete the  Perforce client.
                $self->RunCommand(
                    "$p4Command  client -d $opts->{temp_client}",
                    {
                        LogCommand     => $logCommand,
                        LogResult      => $logResult,
                        HidePassword   => 1,
                        passwordStart  => $passwordStart,
                        passwordLength => $passwordLength
                    }
                );
            }
        }
    }
}

#-------------------------------------------------------------------------
# doSmartSync
#
#      This method is used for reverting the changes over an existing
#      client, synchronize it and prepare it for the preflight.
#
# Results:
#      None.
#
# Side Effects:
#      A file is written containing one section for each line in
#      $changes.  This section contains the name of the user making
#      the change, and the details for the change provided by Perforce.
#
# Arguments:
#      p4Command -     The root p4 command
#      changes -       Output from "p4 changes", listing one change number
#                      on each line.
#      fileName -      Name of file in which to write the details.
#-------------------------------------------------------------------------
sub doSmartSync {
    my ( $self, $opts ) = @_;

    $self->updateOptions($opts);
    $self->debugMsg( 1, "Starting Smart Sync...", $opts );
    my $logResult;
    my $logCommand;
    ( $logResult, $logCommand ) = $self->lvlForCommands($opts);

    my $changeNumber;
    my $scmKey;
    my $start;
    my $parallelSync = "";

    if(length($opts->{parallelSync})) {
        $parallelSync = "--parallel=$opts->{parallelSync}";
    }

    #this is because the client name could be dynamically generated using the template name and the resource name
    $opts->{temp_client} = $self->getClientName($opts);

    # Load userName and password from the credential
    ( $opts->{P4USER}, $opts->{P4PASSWD} )
        = $self->retrieveUserCredential( $opts->{credential}, $opts->{P4USER}, $opts->{P4PASSWD} );

    my ( $p4Command, $passwordStart, $passwordLength ) = $self->setupP4($opts);
    if ( $self->clientExists($p4Command, $opts->{temp_client}) ) {
        $self->error("Cannot use an existing client with Smart Sync.");
    }
    else {
        $self->debugMsg( 3, "Reset all file permissions to Read Only", $opts );

        #set all the files permissions to read-only
        find( \&resetPermissions, $opts->{dest} );
        $self->debugMsg( 3, "Creating the client", $opts );

        #create client and set the root to dest.
        $self->createClient($opts);
        $self->debugMsg( 3, "Running a Perforce flush", $opts );
        $self->RunCommand(
            "$p4Command -c $opts->{temp_client} flush",
            {   LogCommand     => $logCommand,
                HidePassword   => 1,
                LogResult      => $logResult,
                passwordStart  => $passwordStart,
                passwordLength => $passwordLength
            }
        );


        if ( $opts->{deleteFiles} eq '1' ) {
            $self->deleteUntrackedFiles($opts);
        }

        # Extract the number of the most recent changelist.
        $self->debugMsg( 3, "Get the most recent CL", $opts );
        $changeNumber = $opts->{changelist};

        if($changeNumber eq '') {
            ($changeNumber) = $self->getP4LastSnapshotId($opts);
        }

        print "SmartSyncing to CL $changeNumber\n";

        $self->debugMsg( 3, "Sync changed or missing files", $opts );
        $self->syncChangedOrMissingFiles($opts, $changeNumber);
        my $tmp_cmd = "$p4Command -c $opts->{temp_client} sync $parallelSync \@$changeNumber";
        if ( $opts->{debug} eq "6" ) {
            $tmp_cmd = "$p4Command -Ztrack=1 -c $opts->{temp_client} sync $parallelSync \@$changeNumber";
        }
        $self->RunCommand(
            $tmp_cmd,
            {   LogCommand     => $logCommand,
                HidePassword   => 1,
                LogResult      => $logResult,
                passwordStart  => $passwordStart,
                passwordLength => $passwordLength
            }
        );
    }

    #BSH - Get the SCM Key for the temp client
    $scmKey = $self->getKeyFromTemplate( $opts->{temp_client}, defined($opts->{temporaryClient})?$opts->{procedureStepId}:0 );

    #BSH - Find the lastSnapshot info
    $start = "";
    if (length($opts->{lastSnapshot}) )
    {
        # use the lastSnapshot that was passed in.
        # note: don't include
        # the change given by $::gLastSnapshot, since that was already
        # included in the previous build.
        $start = $opts->{lastSnapshot};
    }

    # A perforce label is a valid input parameter
    # We need to convert it into a changelist number for ease of changelog generation
    $changeNumber = $self->resolveLabel($opts, $changeNumber);

    if ( $start eq "" ) {
        $start = $changeNumber;
    }

    $start += 1 if $start != $changeNumber;
    $self->generateChangelog($opts, $scmKey, $start, $changeNumber);

    # bhandley
    # Write out the clientname used for this sync to properties
    # on the job. Some customers use thse settings to issue additional p4 commands
    # in subsequent steps.
    $self->getCmdr()->setProperty( "/myJob/P4CLIENT", $opts->{temp_client} );

    $self->debugMsg( 1, "... Smart Sync complete.", $opts );
}



###############################################################################
# agentPreflight routines  (apf_xxxx)
###############################################################################
#------------------------------------------------------------------------------
# apf_getScmInfo
#
#       If the client script passed some SCM-specific information, then it is
#       collected here.
#------------------------------------------------------------------------------
sub apf_getScmInfo {
    my ( $self, $opts ) = @_;
    my $scmInfo = $self->pf_readFile("ecpreflight_data/scmInfo");
    $scmInfo =~ m/(.*)\n(.*)\n(.*)\n(.*)\n(.*)\n(.*)\n/;
### NMB-9873
    #$opts->{P4PORT} = $1;
###
    $opts->{template} = $2;
### NMB-9873
    #$opts->{P4USER} = $3;
###
    $opts->{changelist} = $4;
# Rollback due to ECPSCMPERFORCE-163
###    $opts->{temp_client} = $5;
    $opts->{stream}     = $6;
    print(    "Perforce information received from client:\n"
            . "Template: $opts->{template}\n"
            . "Stream: $opts->{stream}\n"
            . "Changelist: $opts->{changelist}\n\n" );
    print( "Perforce information from server:\n" . "Port: $opts->{P4PORT}\n" );
}

#------------------------------------------------------------------------------
# apf_createSnapshot
#
#       Create the basic source snapshot before overlaying the deltas passed
#       from the client.
#------------------------------------------------------------------------------
sub apf_createSnapshot {
    my ( $self, $opts ) = @_;
    my $jobStepId = $::ENV{COMMANDER_JOBSTEPID};
    my $result;
    if ( !defined $opts->{temp_client}
        && "$opts->{temp_client}" eq "" )
    {
        $opts->{temp_client} = "ecpreflight-$jobStepId";
        $opts->{temporaryClient} = 1;
    }
    if ( defined $opts->{smartSync}
        && $opts->{smartSync} eq 1 )
    {
        doSmartSync( $self, $opts );
    }
    elsif ( defined $opts->{incremental}
        && $opts->{incremental} eq 1 )
    {
        $self->doIncrementalSync( $opts );
    }
    else {
        $result = $self->checkoutCode($opts);
    }
    if ( defined $result ) {
        print "checked out $result\n";
    }
}

#------------------------------------------------------------------------------
# apf_driver
#
# agent preflight driver for perforce
#------------------------------------------------------------------------------
sub apf_driver() {
    my ( $self, $opts ) = @_;

    $opts->{apf_running} = "1";
    if ( $opts->{test} ) {
        $self->setTestMode(1);
    }
    $opts->{delta} = "ecpreflight_files";
    $self->apf_downloadFiles($opts);
    $self->apf_transmitTargetInfo($opts);
    $self->apf_getScmInfo($opts);
    $self->apf_createSnapshot($opts);
    $self->apf_setmapping($opts);
    $self->apf_deleteFiles($opts);
    $self->apf_overlayDeltas($opts);
    $self->cleanup($opts);
}

#------------------------------------------------------------------------------
# apf_setmapping
#
#       Will fix the different mapping between clients, that way the preflight
#     overlay the deltas correctly.
#------------------------------------------------------------------------------
sub apf_setmapping {
    my ( $self, $opts ) = @_;
    my $oldUmask = umask;
    my $here     = cwd();
    my $logCommand;
    my $logResult;
    my $filenum = 0;
    my $bparam  = '';

    $self->updateOptions($opts);
    my $client = $opts->{permanent_client} || $opts->{temp_client};
    ( $logResult, $logCommand ) = $self->lvlForCommands($opts);
    umask(0000);
    $self->debugMsg( 1, "Fixing the mappings", $opts );
    my $versionChecked = 0;
    if ( $self->getP4Version($opts) >= 20111 ) {
        $versionChecked = 1;
    }

    #fix the mappings for the deletes file
    if (   -e "ecpreflight_data/deletes"
        && -s "ecpreflight_data/deletes" > 0 )
    {
        move( "ecpreflight_data/deletes", "ecpreflight_data/deletes_origin" );
        my ( $p4Command, $passwordStart, $passwordLength ) = $self->setupP4($opts);
        my $deletes_origin;
        open( DELETES_ORIGIN, "$here/ecpreflight_data/deletes_origin" )
            or die $!;
        $deletes_origin = do {
            local $/;
            <DELETES_ORIGIN>;
        };
        close(DELETES_ORIGIN);
        my @deletes = split( /\n/, $deletes_origin );
        open( DELETES_ORIGIN_TMP, "> $here/ecpreflight_data/deletes_origin_tmp" )
            or die $!;
        foreach (@deletes) {
            my $delete = $_;
            $delete = $self->ASCIIExpansion($delete);
            print DELETES_ORIGIN_TMP "$delete\n";
        }
        close(DELETES_ORIGIN_TMP);
        chdir( $opts->{dest} );
        $filenum = 0;
        $bparam  = '';
        if ($versionChecked) {
            $filenum = $self->countFileLines("$here/ecpreflight_data/deletes_origin_tmp");
            $bparam  = " -b $filenum ";
        }
        my $clientOutput = $self->RunCommand(
            "$p4Command -s -c \"$client\" $bparam-x \"$here/ecpreflight_data/deletes_origin_tmp\" fstat -Rc -Op -T \"path\"",
            {   LogCommand     => $logCommand,
                HidePassword   => 1,
                LogResult      => 1,                #$logResult,
                passwordStart  => $passwordStart,
                passwordLength => $passwordLength
            }
        );
        chdir($here);
        if ($clientOutput) {
            $clientOutput =~ s/exit\:\s0\n//ixmg;
        }
        my @lines = split( /\n/, $clientOutput );
        open( DELETES, ">", "ecpreflight_data/deletes" )
            or die $!;
        foreach (@lines) {
            if ( $_ ne q{} ) {
                $_ =~ m/.*\spath\s(.*)/;

                my $delete = $1;
                my $base = substr( $delete, 0, length( $opts->{dest} ) );
                if ( $base eq $opts->{dest} ) {
                    if ( $opts->{dest} =~ /\/$|\\$/ ) {
                        $delete = substr( $delete, length( $opts->{dest} ) );
                    }
                    else {
                        $delete = substr( $delete, length( $opts->{dest} ) + 1 );
                    }
                }
                else {
                    $delete = File::Spec->abs2rel( $delete, $opts->{dest} );
                }
                print DELETES "$delete\n";
            }
        }
        close(DELETES);
    }
    if (   -e "ecpreflight_data/deltas"
        && -s "ecpreflight_data/deltas" > 0 )
    {
        move( "ecpreflight_data/deltas", "ecpreflight_data/deltas_origin" );
        move( "ecpreflight_files",       "ecpreflight_files_origin" );
        mkpath('ecpreflight_files');
        my ( $p4Command, $passwordStart, $passwordLength ) = $self->setupP4($opts);
        my $deltas_origin;
        open( DELTAS_ORIGIN, "$here/ecpreflight_data/deltas_origin" )
            or die $!;
        $deltas_origin = do {
            local $/;
            <DELTAS_ORIGIN>;
        };
        close(DELTAS_ORIGIN);
        my @deltas = split( /\n/, $deltas_origin );
        open( DELTAS_ORIGIN_TMP, "> $here/ecpreflight_data/deltas_origin_tmp" )
            or die $!;
        foreach (@deltas) {
            my $delta = $_;
            $delta = $self->ASCIIExpansion($delta);
            print DELTAS_ORIGIN_TMP "$delta\n";
        }
        close(DELTAS_ORIGIN_TMP);
        chdir( $opts->{dest} );
        $filenum = 0;
        $bparam  = '';
        if ($versionChecked) {
            $filenum = $self->countFileLines("$here/ecpreflight_data/deltas_origin_tmp");
            $bparam  = " -b $filenum ";
        }

        #this log should not be printed, contains the word error, so the postp will turn the job red
        my $fstat = $self->RunCommand(
            "$p4Command -s -c \"$client\" $bparam-x \"$here/ecpreflight_data/deltas_origin_tmp\" fstat -Op -T \"path depotFile\"",
            {   LogCommand     => $logCommand,
                HidePassword   => 1,
                LogResult      => 0,
                passwordStart  => $passwordStart,
                passwordLength => $passwordLength
            }
        );
        chdir($here);
        my $tmp_fstat = $fstat;
        if ($tmp_fstat) {
            $tmp_fstat =~ s/(path\s.*\n)/$1\n/ixmg;
            $tmp_fstat =~ s/exit\:\s0\n//ixmg;
            $tmp_fstat =~ s/error\:\s.*\n//ixmg;
        }
        my @lines = split( /\n{2,}/, $tmp_fstat );
        open( DELTAS, ">", "ecpreflight_data/deltas" )
            or die $!;
        foreach (@lines) {
            if ( $_ ne q{} ) {
                my $to;
                my $from;
                if ( $_ =~ m/.*\sdepotFile\s(.*)\n.*\spath\s(.*)/ ) {
                    $to = $2;
                    my $base = substr( $to, 0, length( $opts->{dest} ) );
                    if ( $base eq $opts->{dest} ) {
                        if ( $opts->{dest} =~ /\/$|\\$/ ) {
                            $to = substr( $to, length( $opts->{dest} ) );
                        }
                        else {
                            $to = substr( $to, length( $opts->{dest} ) + 1 );
                        }
                    }
                    else {
                        $to = File::Spec->abs2rel( $to, $opts->{dest} );
                    }
                    $to = $self->ASCIIContraction($to);
                    print DELTAS "$to\n";
                    $to   = File::Spec->catfile( "ecpreflight_files",        $to );
                    $from = File::Spec->catfile( "ecpreflight_files_origin", $1 );
                    $from =~ s/\/\//\//g;
                    my ( $volume, $directories, $file ) = File::Spec->splitpath($to);
                    if ( !-e $directories ) {

                        if ( $directories ne '' ) {
                            mkpath($directories);
                        }
                    }
                    $self->apf_copyAndPreserve( $from, $to );
                }
            }
        }
        @lines = split( /\n/, $fstat );
        foreach (@lines) {
            if ( $_ ne q{} ) {
                my $to;
                my $from;
                my $file;
                my $file_tmp;
                my $depotFile;
                if ( $_ =~ m/error\:\s(.*)\s\-\sno such file\(s\)./ ) {
                    $file      = $1;
                    $depotFile = $file;
                    my $location = $self->RunCommand(
                        "$p4Command -c \"$client\"  -z tag where \"$file\"",
                        {   LogCommand     => $logCommand,
                            HidePassword   => 1,
                            LogResult      => $logResult,
                            passwordStart  => $passwordStart,
                            passwordLength => $passwordLength
                        }
                    );
                    $file =~ m/\/\/(.*?)\/.*/;
                    if ( $location =~ m/.*clientFile\s(.*)\n/ ) {
                        $file = $1;
                        if ( $file =~ m/^\/\// ) {
                            $file =~ m/\/\/$client\/(.*)/;    #removing //clientName
                            $file_tmp = $1;
                        }
                        elsif ( $file =~ m/^\// ) {
                            $file =~ m/\/$client\/(.*)/;      #removing //clientName
                            $file_tmp = $1;
                        }
                        $from = File::Spec->catfile( "ecpreflight_files_origin/", $depotFile );
                        $file_tmp = $self->ASCIIContraction($file_tmp);
                        print DELTAS "$file_tmp\n";
                        $to = File::Spec->catfile( "ecpreflight_files", $file_tmp );
                        my ( $volume, $directories, $file ) = File::Spec->splitpath($to);
                        if ( !-e $directories ) {
                            if ( $directories ne '' ) {
                                mkpath($directories);
                            }
                        }
                        $from = $self->ASCIIContraction($from);
                        $to   = $self->ASCIIContraction($to);
                        $self->apf_copyAndPreserve( $from, $to );
                    }
                }
            }
        }
        close(DELTAS);
    }
    umask($oldUmask);
    $self->debugMsg( 1, "Mappings fixed.", $opts );
}
###############################################################################
# clientPreflight routines  (cpf_xxxx)
###############################################################################
#------------------------------------------------------------------------------
# cpf_p4
#
#       Runs a p4 command.  For testing, the requests and responses will be
#       pre-arranged.
#------------------------------------------------------------------------------
sub cpf_p4 {
    my ( $self, $opts, $command, $options ) = @_;
    if ( $opts->{scm_client} eq "" ) {
        $self->cpf_debug("Blank client passed into cpf_p4");
        return "";
    }
    $self->cpf_debug("Running Perforce command \"$command\"");
    my $curDir = $self->pf_getCurrentWorkingDir();
    if ( $opts->{opt_Testing} ) {
        my $request = uc("p4_$command");
        $request =~ s/[^\w]//g;
        if ( defined( $ENV{$request} ) ) {
            return $ENV{$request};
        }
        else {
            $self->cpf_error("Pre-arranged command output for [$request] not found in ENV");
        }
    }
    else {
        if ( $curDir !~ /(^\D\:\\$|^\/$)/i ) {
            return $self->RunCommand( "p4 -c " . $opts->{scm_client} . " -d \"$curDir\" $command", $options );
        }
        else {
            return $self->RunCommand( "p4 -c " . $opts->{scm_client} . " $command", $options );
        }
    }
}



#------------------------------------------------------------------------------
# copyDeltas
#
#       Finds all new and modified files and either copies them directly to
#       the job's workspace or transfers them via the server using putFiles.
#       The job is kicked off once the sources are ready to upload.
#------------------------------------------------------------------------------
sub cpf_copyDeltas {
    my ( $self, $opts ) = @_;
    $self->cpf_display("Collecting delta information");
    $self->cpf_saveScmInfo( $opts,
              $opts->{scm_port} . "\n"
            . $opts->{scm_template} . "\n"
            . $opts->{scm_user} . "\n"
            . $opts->{rt_syncToChangelist} . "\n"
            . $opts->{scm_client} . "\n"
            . $opts->{scm_stream}
            . "\n" );
    $self->cpf_findTargetDirectory($opts);
    $self->cpf_createManifestFiles($opts);

    # Collect a list of opened files.
    my $output         = "";
    foreach my $changelist ( @{ $opts->{rt_changelists} } ) {
        my $o = $self->cpf_p4(
            $opts,
            "opened -c $changelist",
            {   IgnoreError => 0,
                DieOnError  => 1
            }
        );
        $o =~ s/File\(s\) not opened on this client.\s//gm;
        $output .= $o;
    }
    chomp $output;
    $self->cpf_debug("output from opened=[$output]");
    if (   $output eq ""
        || $output =~ /not opened on this client/ )
    {
        $self->cpf_error("No file changes found.");
    }
    $opts->{rt_openedFiles} = $output;
    my @files;
    foreach ( split( /\n/, $output ) ) {

        # Parse the output from p4 opened and figure out the file name and what
        # type of change is being made.
        $_ =~ m/(.*)#.* \- (edit|add|delete|branch|integrate|move\/add|move\/delete) (.*)/;
        my $file = $1;
        my $type = $2;
        push( @files, "$type\t$file" );
    }

    #save the file list to a temp file
    my $filelist = File::Temp->new( UNLINK => 0 );
    my $filelist_filename = undef;
    if ( !$opts->{opt_Testing} ) {
        $filelist_filename = $filelist->filename;
        foreach (@files) {
            $_ =~ m/(.*)\t(.*)/;
            $filelist->print("$2\n");
        }
        $filelist->flush();
        $filelist->seek( 0, 0 );
    }
    else {
        $filelist_filename = $opts->{test_filename};
    }
    my $versionChecked = 0;
    if ( $self->getP4Version($opts) >= 20111 ) {
        $versionChecked = 1;
    }
    my $filenum = 0;
    my $bparam  = '';
    if ($versionChecked) {
        $filenum = $self->countFileLines($filelist_filename);
        $bparam  = "-b $filenum ";
    }

    $self->checkForConflicts($bparam,$filelist_filename,$opts);

    # Run "p4 fstat" on the opened files to determine the source
    # and destination paths to pass to the putFiles operation.
    my $fstat = $self->cpf_p4( $opts, "-s $bparam-x \"$filelist_filename\" fstat -Op -T \"path depotFile action\"" );
    if ($fstat) {
        #$fstat =~ s/(action\s.*\n)/$1\n/ixmg;
        #$fstat =~ s/exit\:\s0\n//ixmg;
        $fstat =~ s/(\:\ action\s.*\n)/$1\n/ixmg;
        $fstat =~ s/^exit\:\s0\n//ixmg;
    }
    my @fstats = split( /\n{2,}/, $fstat );
    foreach (@fstats) {
        #if ( $_ =~ /.*depotFile\s(.*)\n.*path\s(.*)\n.*action\s(.*)/ ) {
        if ($_ =~ /.*:\s*depotFile\s(.*)\n.*:\s*path\s(.*)\n.*:\s*action\s(.*)/) {
            my $dest     = $1;
            my $source   = $2;
            my $action   = $3;
            my $filename = basename($source);
            my $dir      = dirname($dest);
            $dest = "$dir" . '/' . "$filename";
            $dest =~ s/\\/\//g;
            if (   $action ne "delete"
                && $action ne "move/delete" )
            {
                $self->cpf_addDelta( $opts, $source, $dest );
            }
            else {
                $self->cpf_addDelete($dest);
            }
        }
    }
    $self->cpf_closeManifestFiles($opts);
    $self->cpf_uploadFiles($opts);
}

#------------------------------------------------------------------------------
# autoCommit
#
#       Automatically commit changes in the user's client.  Error out if:
#       - A check-in has occurred since the preflight was started, and the
#         policy is set to die on any check-in.
#       - A check-in has occurred and opened files are out of sync with the
#         head of the branch.
#       - A check-in has occurred and non-opened files are out of sync with
#         the head of the branch, and the policy is set to die on any changes
#         within the client workspace.
#------------------------------------------------------------------------------
sub cpf_autoCommit() {
    my ( $self, $opts ) = @_;

    # Make sure none of the files have been touched since the build started.
    $self->cpf_checkTimestamps($opts);

    # Check the contents of the changelist(s).  If there have been any changes,
    # error out.
    my $output = "";
    foreach my $changelist ( @{ $opts->{rt_changelists} } ) {
        $output .= $self->cpf_p4( $opts, "opened -c $changelist", { DieOnError => 0 } );
    }
    chomp $output;
    if ( $output ne $opts->{rt_openedFiles} ) {
        $self->cpf_error( "Files have been added and/or removed from the selected "
                . "changelists since the preflight build was launched" );
    }

    # Find the latest checked-in changelist number and compare it to the
    # previously stored changelist number.  If they are the same, then proceed.
    # Otherwise, do some more advanced checks for conflicts.
    my $out = $self->cpf_p4( $opts, "changes -m1" );
    $out =~ m/Change ([\d]+).*/;
    my $latestChange = $1;
    $self->cpf_debug("Latest checked-in changelist: $latestChange");
    if ( $latestChange ne $opts->{rt_syncToChangelist} ) {

        # If the changelists are different, then check the policies.  If it is
        # set to always die on new check-ins, then error out.
        if ( $opts->{opt_DieOnNewCheckins} ) {
            $self->cpf_error( "A check-in has been made since ecpreflight was started. "
                    . "Sync and resolve conflicts, then retry the preflight "
                    . "build" );
        }

        # If there are any files that overlap with the opened files, then
        # check the policies.  If it is set to always die, then error out.
        # Otherwise, try to auto-resolve.
        # always error out.  If there is no overlap, then check the policies.
        # If it is set to always die on overlaps, then error out.
        my $output = $self->cpf_p4( $opts, "sync -n", { DieOnError => 0 } );
        if (   $opts->{opt_DieOnWorkspaceChanges}
            && $output !~ m/File\(s\) up-to-date./ )
        {
            $self->cpf_error( "The client \"$opts->{scm_client}\" is out of sync with the "
                    . "head. Sync and resolve conflicts, then retry the "
                    . "preflight build" );
        }
        elsif ( $output =~ m/must resolve .* before submitting/ ) {
            if ( $opts->{opt_DieOnFileChanges} ) {
                $self->cpf_error( "Opened files are out of sync with the head. Sync and "
                        . "resolve conflicts, then retry the preflight build" );
            }
            else {
                $self->cpf_p4( $opts, "sync", { DieOnError => 0 } );
                my $output = $self->cpf_p4( $opts, "resolve -am", { DieOnError => 0 } );
                if ( $output =~ m/resolve skipped/ ) {
                    $self->cpf_error( "Could not auto-resolve conflicts. Manually "
                            . "resolve conflicts, then retry the preflight "
                            . "build" );
                }
            }
        }
    }

    # Commit the changelists one at a time.  Use the commit description for the
    # default changelist, if it's being submitted.
    $self->cpf_display("Committing changes");
    foreach my $changelist ( @{ $opts->{rt_changelists} } ) {
        if ( $changelist ne "default" ) {
            $self->cpf_p4( $opts, "submit -c $changelist", { DieOnError => 1 } );
        }
        else {
            $self->cpf_p4( $opts, "submit -d \"" . $opts->{scm_commitComment} . "\"", { DieOnError => 1 } );
        }
    }
    $self->cpf_display("Changes have been successfully submitted");
}

#------------------------------------------------------------------------------
# processOptions
#
#       processOptions for this preflight client driver
#------------------------------------------------------------------------------
sub cpf_processOptions {
    my ( $self, $opts ) = @_;
    $::gHelpMessage .= "
Perforce Options:
  --p4port <port>           The value of P4PORT.  May also be set in the
                            environment or using p4 set.
  --p4user <user>           The value of P4USER.  May also be set in the
                            environment or using p4 set.
                            not specified.
  --p4passwd <password>     The value of P4PASSWD.  May also be set in the
                            environment or using p4 set.
  --p4client <client>       The value of P4CLIENT.  May also be set in the
                            environment or using p4 set.
  --p4template <template>   The name of a Perforce client used to create a base
                            snapshot before overlaying local changes.  Defaults
                            to the value of --p4client if not specified.
  --p4stream   <stream>     The name of a Perforce stream used to create a base
                            snapshot before overlaying local changes.
  --p4changelist <change>   The changelist number (or default) whose changes
                            are being tested.  May be specified multiple times.
                            If no changelists are specified, all changelists
                            for the client will be used.
  --p4synctochange <change> The changelist number that the Preflight Job should
                            use when sync'ing the source tree.  Values are:
                                head    -   The most recent changelist
                                            anywhere in the P4 depot.
                                            (default)
                                have    -   The changelist of the most recent
                                            file that has been synced to
                                            'p4client'
                                changelist  A p4 changelist number
"
        ;
## override config file with command line options
## use p4xxx for backwards compatibility
    my @clists;
    my %ScmOptions = (
        "p4port=s"         => \$opts->{scm_port},
        "p4user=s"         => \$opts->{scm_user},
        "p4passwd=s"       => \$opts->{scm_password},
        "p4client=s"       => \$opts->{scm_client},
        "p4template=s"     => \$opts->{scm_template},
        "p4stream=s"       => \$opts->{scm_stream},
        "p4changelist=s"   => \@clists,
        "p4synctochange=s" => \$opts->{scm_synctochange},
    );
    Getopt::Long::Configure("default");
    if ( !GetOptions(%ScmOptions) ) {
        $self->cpf_error($::gHelpMessage);
    }
    if ( $::gHelp eq "1" ) {
        $self->cpf_display($::gHelpMessage);
        return 0;
    }

    # Collect SCM-specific information from the configuration
    # since p4 set can be used to set vals, we dont make most of these required
    $self->extractOption( $opts, "scm_port",     { env => "P4PORT" } );
    $self->extractOption( $opts, "scm_user",     { env => "P4USER" } );
    $self->extractOption( $opts, "scm_password", { env => "P4PASSWD" } );
    $self->extractOption(
        $opts,
        "scm_client",
        {   env      => "P4CLIENT",
            required => 1
        }
    );
    $self->extractOption( $opts, "scm_template", { env => "P4TEMPLATE" } );
    $self->extractOption( $opts, "scm_stream",   { env => "P4STREAM" } );
    $self->extractOption( $opts, "scm_synctochange" );

    if (( !defined( $opts->{scm_template} ) || $opts->{scm_template} eq "" )
        && ( !defined( $opts->{scm_stream} )
            || $opts->{scm_stream} eq "" )
        )
    {
        $opts->{scm_template} = $opts->{scm_client};
    }
    $opts->{scm_synctochange} = "head"
        unless ( $opts->{scm_synctochange} );
    $opts->{rt_defaultChangelist} = 0;
## add explicit p4changelist args on command line
    if (@clists) {

        # add to changelist(s) from cmd line args
        foreach my $c (@clists) {
            push( @{ $opts->{rt_changelists} }, $c );
            $self->debug("Adding changelist $c from command line option");
        }
    }

    # if no commandline changelists specified, look in preflight file
    if (  !defined( $opts->{rt_changelists} )
        || scalar( @{ $opts->{rt_changelists} } ) == 0 )
    {
        if ( defined( $opts->{scm_changelist} )
            && $opts->{scm_changelist} ne "" )
        {

            # main driver will concat multiple entries from preflight file into
            # one option with | separator
            my @changes = split( /\|/, $opts->{scm_changelist} );
            for my $c (@changes) {
                push( @{ $opts->{rt_changelists} }, $c );
                $self->debug("Adding changelist $c from preflight file entry");
            }
        }
    }
    foreach my $cl ( @{ $opts->{rt_changelists} } ) {
        if ( $cl eq "default" ) {
            $opts->{rt_defaultChangelist} = 1;
        }
    }
    return 1;
}

#------------------------------------------------------------------------------
# driver
#
#       Main program for the application.
#------------------------------------------------------------------------------
sub cpf_driver {
    my ( $self, $opts ) = @_;
    if ( defined( $ENV{FAKE_P4_SERVER} )
        && $ENV{FAKE_P4_SERVER} ne "" )
    {
        $self->cpf_display("Using a fake Perforce server for testing");
        $opts->{opt_Testing} = 1;
    }
    if ( defined( $ENV{"ECPREFLIGHT_TEST_DRIVER"} )
        && $ENV{"ECPREFLIGHT_TEST_DRIVER"} ne "" )
    {

        # test code has been loaded... run this instead of real driver
        my $testDriver = $ENV{"ECPREFLIGHT_TEST_DRIVER"};
        eval $testDriver;
        if ($@) {
            print "Error running test script:$@\n";
            print "Script[$testDriver]\n";
        }
        return;
    }
    $self->cpf_display("Executing Perforce actions for ecpreflight");
    if ( !$self->cpf_processOptions($opts) ) {
        return;
    }
    $self->cpf_debug("port=$opts->{scm_port}");
    $self->cpf_debug("user=$opts->{scm_user}");
    $self->cpf_debug("client=$opts->{scm_client}");
    $self->cpf_debug("template=$opts->{scm_template}");
    $self->cpf_debug("stream=$opts->{scm_stream}");
    $self->cpf_debug("changelist=$opts->{scm_changelist}");

    # If no changelists were specified by the user, then add all pending
    # changelists.
    if ( scalar( @{ $opts->{rt_changelists} } ) == 0 ) {
        $self->cpf_display("No changelists defined; using all pending changelists");

        # Check to see if the default changelist has opened files.  If it does,
        # then add it to the set of changelists.
        my $defaultOpened = $self->cpf_p4( $opts, "opened -c default", { DieOnError => 1 } );
        if ( $defaultOpened !~ m/File\(s\) not opened on this client./ ) {
            $self->cpf_debug("Adding changelist default");
            push( @{ $opts->{rt_changelists} }, "default" );
            $opts->{rt_defaultChangelist} = 1;
        }

        # Add all saved changelists.
        my $pendingChangelists = $self->cpf_p4(
            $opts,
            "changelists -s pending -c " . "\"" . $opts->{scm_client} . "\"",
            { DieOnError => 1 }
        );
        foreach my $line ( split( /\n/, $pendingChangelists ) ) {
            if ( $line =~ m/Change (\d*) .*/ ) {
                $self->cpf_debug("Adding changelist $1");
                push( @{ $opts->{rt_changelists} }, $1 );
            }
        }
    }
    if ( scalar( @{ $opts->{rt_changelists} } ) == 0 ) {
        $self->cpf_error( "No active changelists found in client \"" . $opts->{scm_client} . "\"" );
    }

    # If the default changelist is being used and the preflight is set to
    # auto-commit, then require a commit comment.
    if (   $opts->{scm_autoCommit}
        && $opts->{rt_defaultChangelist}
        && ( !defined( $opts->{scm_commitComment} )
            || $opts->{scm_commitComment} eq "" )
        )
    {
        $self->cpf_error( "A changelist description is required when running a job when "
                . "autocommit is enabled.  May also be passed on the command "
                . "line using --commitComment" );
    }

    # Login to Perforce if a password is specified.  Otherwise, do nothing.
    if ( defined( $opts->{scm_password} )
        && $opts->{scm_password} ne "" )
    {
        $self->cpf_debug("Logging into Perforce");
        $self->cpf_p4( $opts, "login " . $opts->{scm_user}, { input => $opts->{scm_password} }, { DieOnError => 1 } );
    }
    else {
        $self->cpf_debug("Bypassing Perforce login since no password was specified");
    }

    # There are 3 changelists that we are interested in here
    #       latest - The most recent Perforce changelist
    #                  (global, not specific to any client or client definition)
    #       synced - The most recent changelist that the developer's client
    #                  is synced to
    #       syncto - The one that we want the agent to sync to when running the
    #                  preflight.  This will be passed in, either as a
    #                  number, or a special string, or it will be defaulted to
    #                  be the same as the latest
    # Store the latest checked-in changelist number.
    my $out = $self->cpf_p4( $opts, "changes -m1", { DieOnError => 1 } );
    $out =~ m/Change ([\d]+).*/;
    $opts->{rt_latestChangelist} = $1;
    $self->cpf_debug( "Latest checked-in changelist: " . $opts->{rt_latestChangelist} );

    #  This will be used to sync the agent when running the preflight job
    if ( $opts->{scm_synctochange} eq "head" ) {
        $opts->{rt_syncToChangelist} = $opts->{rt_latestChangelist};
    }
    elsif ( $opts->{scm_synctochange} eq "have" ) {

        # Store the changelist number that the client is synced to
        my $out = $self->cpf_p4( $opts, "changes -m1 \@$opts->{scm_client}", { DieOnError => 1 } );

        # Check if we can match this string.
        if ( $out =~ m/Change ([\d]+).*/ ) {
            $opts->{rt_syncToChangelist} = $1;
            $self->cpf_debug( "Latest changelist that client was synced to: " . $opts->{rt_syncedChangelist} );
        }
        else {
            $self->cpf_error("Couldn't find the last change synced");
        }
    }
    else {

        # Error out if the user has opened any out-of-date files.
        $opts->{rt_syncToChangelist} = $opts->{scm_synctochange};
    }

    # Copy the deltas to a specific location.
    $self->cpf_copyDeltas($opts);

    # Auto commit if the user has chosen to do so.
    if ( $opts->{scm_autoCommit} ) {
        if ( !$opts->{opt_Testing} ) {
            $self->cpf_waitForJob($opts);
        }
        $self->cpf_autoCommit($opts);
    }
}
###############################################
# debugMsg
#
# print a message if debug level permits
#
# args
#   lvl  - the debug level for this message
#   msg  - the message to show
#
###############################################
sub debugMsg {
    my ( $self, $lvl, $msg, $opts ) = @_;
    if ( $self->getDbg($opts) >= $lvl ) {
        print "$msg\n";
    }
}
######################################
# getDbg
#
# Get the Dbg level
######################################
sub getDbg {
    my ( $self, $opts ) = @_;
    if ( !defined $opts->{debug}
        || $opts->{debug} eq "" )
    {
        return 0;
    }
    else {
        return $opts->{debug};
    }
}
######################################
# lvlForCommands
#
# Determines if log command or result
# depending of the debug level
######################################
sub lvlForCommands {
    my ( $self, $opts ) = @_;
    my $logResult;
    my $logCommand;
    if ( $opts->{debug} >= 5 ) {
        $logResult  = 1;
        $logCommand = 1;
    }
    elsif ( $opts->{debug} eq "3" ) {
        $logCommand = 1;
        $logResult  = 0;
    }
    else {
        $logResult  = 0;
        $logCommand = 0;
    }
    return ( $logResult, $logCommand );
}
######################################
# ASCIIExpansion
#converts p4 regular path to ASCII expanded
######################################
sub ASCIIExpansion {
    my ( $self, $string ) = @_;
    $string =~ s/\%/\%25/g;
    $string =~ s/\@/\%40/g;
    $string =~ s/\#/\%23/g;
    $string =~ s/\*/\%2A/g;
    $string =~ s/\\/\//g;
    return ($string);
}
######################################
# ASCIIContraction
#converts p4 ASCII expanted path to the regular path
######################################
sub ASCIIContraction {
    my ( $self, $string ) = @_;
    $string =~ s/\%25/\%/g;
    $string =~ s/\%40/\@/g;
    $string =~ s/\%23/\#/g;
    $string =~ s/\%2A/\*/g;
    $string =~ s/\\/\//g;
    return ($string);
}
######################################
# getP4Version
#
# Return the version of the current client
#
######################################
sub getP4Version {
    my ( $self, $opts ) = @_;
    my ( $p4Command, $passwordStart, $passwordLength ) = $self->setupP4($opts);
    my $output = $self->RunCommand(
        "$p4Command -V",
        {   LogCommand     => 0,
            HidePassword   => 1,
            LogResult      => 0,
            passwordStart  => $passwordStart,
            passwordLength => $passwordLength
        }
    );
    $output =~ m/(\d+\.\d+)/;
    my $version = $1;
    $version =~ s/\.//;
    return $version;
}
######################################
# countFileLines
#
# Return the number of lines of a file
#
######################################
sub countFileLines {
    my ( $self, $filename, $opts ) = @_;
    my $lines = 0;
    open( FILE, $filename )
        or die "Can't open '$filename': $!";
    $lines++ while (<FILE>);
    close FILE;
    return $lines;
}
######################################
# getClientSpec
#
# Return the spec of a given client
#
######################################
sub getClientSpec {
    my ( $self, $client, $opts ) = @_;

    $self->updateOptions($opts);
    my ( $p4Command, $passwordStart, $passwordLength ) = $self->setupP4($opts);
    my $base = $self->RunCommand(
        "$p4Command client -o -t $client $client",
        {   LogCommand     => 0,
            HidePassword   => 1,
            passwordStart  => $passwordStart,
            passwordLength => $passwordLength
        }
    );
    return $base;
}
########################################################################
# registerReports - creates a link for registering the generated report
# in the job step detail
#
# Arguments:
#   -none
#
# Returns:
#   -nothing
#
########################################################################
sub registerReports {
    my $self     = shift;
    my $fileName = shift;
    if ( $fileName ne '' ) {
        my $ec = ElectricCommander->new;
        $ec->abortOnError(0);
        $ec->setProperty( "/myJob/artifactsDirectory",                '' );
        $ec->setProperty( "/myJob/report-urls/ECSCM-Perforce Report", "jobSteps/$[jobStepId]/" . $fileName );
    }
}


########################################################################
# getP4LastSnapshotId - Get the last snapshot id from Depot
#
# Arguments:
#   $opts - options passed in from caller
#   $depotPath - optional, path in depot
#
# Returns:
#   - array of id and timestamp of last snapshot
#
########################################################################
sub getP4LastSnapshotId {
    my ($self, $opts, $depotPath) = @_;
    my $p4Command;

    my $clientOpt = defined($opts->{temp_client}) ? "-c $opts->{temp_client}" : "";

    # If the depotPath is specified, it takes precedence
    if($depotPath) {
      $p4Command = "$self->{p4Command} $clientOpt changes -s submitted -t -m 1 $depotPath";
    } else {
      $p4Command = "$self->{p4Command} $clientOpt changes -s submitted -t -m 1 //$opts->{temp_client}/...";
    }

    # Extract the number of the most recent changelist.
    my $p4Opts = {
        LogCommand     => 1,
        LogResult      => 1,
        HidePassword   => 1,
        passwordStart  => $self->{passwordStart},
        passwordLength => $self->{passwordLength}
    };

    my $changeNumber = $self->RunCommand($p4Command, $p4Opts);
    my $timezone = $self->getServerTimeZone($opts);
    require DateTime; # don't use DateTime, because it can break preflight

    if ($changeNumber =~ '^Change ([\d]+) on ([\d]+)/([\d]+)/([\d]+) ([\d]+):([\d]+):([\d]+)') {
        # Extract the changeset number and the date and time components
        #    Change 19863 on 2006/10/23 10:34:19 by sven@sdelmas-main 'Migrating from 3.6 to main. '
        $changeNumber = $1;
        my $changeTime = DateTime->new( year => $2, month => $3, day => $4, hour => $5, minute => $6, second => $7, time_zone => $timezone)->epoch;
        return ($changeNumber, $changeTime);
    }

    $self->debug(1, "Warning: Unexpected output from p4 changes: \"$changeNumber\"\n");
    return (undef, undef);
}


sub getServerTimeZone {
    my ($self, $opts) = @_;

    my $p4Command = "$self->{p4Command} info";
    # Extract the number of the most recent changelist.
    my $p4Opts = {
        LogCommand     => 1,
        LogResult      => 1,
        HidePassword   => 1,
        passwordStart  => $self->{passwordStart},
        passwordLength => $self->{passwordLength}
    };

    my $serverInfo = $self->RunCommand($p4Command, $p4Opts);
    $serverInfo =~ m#Server\sdate:\s\d{4}/\d{2}/\d{2}\s\d{2}:\d{2}:\d{2}\s([-+]?\d{4})#msx;
    my $timeZoneDiff = $1;
    return $timeZoneDiff;
}


####################################################################
# createLinkToChangelogReport
#
# Side Effects:
#   If /myJob/ecscm_changelogs exists, create a report-urls link
#
# Arguments:
#   self -              the object reference
#   reportName -        the name of the report
#
# Returns:
#   Nothing.
####################################################################
sub createLinkToChangelogReport {
    my ( $self, $reportName ) = @_;
    my $name = $self->getCfg()->getSCMPluginName();
    my ( $success, $xpath, $msg ) = $self->InvokeCommander(
        {   SuppressLog  => 1,
            IgnoreError => 1
        },
        "getProperty",
        "/plugins/$name/pluginName"
    );
    if ( !$success ) {
        print "Error getting promoted plugin name for $name: $msg\n";
        return;
    }
    my $root = $xpath->findvalue('//value')->string_value;
    ( $success, $xpath, $msg ) = $self->InvokeCommander(
        {   SuppressLog  => 1,
            IgnoreError => 1
        },
        "getProperty",
        "/myJob/jobId"
    );
    if ( !$success ) {
        print "Error getting jobId: $msg\n";
        return;
    }
    my $id     = $xpath->findvalue('//value')->string_value;
    my $prop   = "/myJob/report-urls/$reportName";
    my $target = "/commander/pages/$root/reports?jobId=$id";

    # e.g. /commander/pages/EC-DefectTracking-JIRA-1.0/reports?debug=1?jobId=510
    print "Creating link $target\n";
    ( $success, $xpath, $msg ) = $self->InvokeCommander(
        {   SuppressLog => 1,
            IgnoreError => 1
        },
        "setProperty",
        "$prop",
        "$target"
    );
    if ( !$success ) {
        print "Error trying to set property $prop: $msg\n";
    }
}

#-------------------------------------------------------------------------
#
#  Find the name of the Project of the current job and the
#  Schedule that was used to launch it
#
#  Params
#       None
#
#  Returns
#       projectName  - the Project name of the running job
#       scheduleName - the Schedule name of the running job
#
#  Notes
#       scheduleName will be an empty string if the current job was not
#       launched from a Schedule
#
#-------------------------------------------------------------------------
sub GetProjectAndScheduleNames {
    my $self                 = shift;
    my $gCachedScheduleName  = "";
    my $gCachedProjectName   = "";
    my $gCachedProcedureName = "";
    if ( $gCachedScheduleName eq "" ) {

        # Call Commander to get info about the current job
        my ( $success, $xPath ) = $self->InvokeCommander( { SuppressLog => 1 }, "getJobInfo", $ENV{COMMANDER_JOBID} );

        # Find the schedule name in the properties
        $gCachedScheduleName  = $xPath->findvalue('//scheduleName');
        $gCachedProjectName   = $xPath->findvalue('//projectName');
        $gCachedProcedureName = $xPath->findvalue('//procedureName');
    }
    return ( $gCachedProjectName, $gCachedScheduleName, $gCachedProcedureName );
}


#---------------------
# checkForConflicts
# Check to see if the preflight should be stopped due to conflicts such as
# out of date files or files that have conflicts
#
# Args:
#   bparam - batch size parameter
#   filename - p4 client will read from this file
#   opts  - options passed in from caller
#---------------------
sub checkForConflicts {

    my ($self, $bparam, $filename, $opts) = @_;

    my $checkConflicts = $self->cpf_p4( $opts, "$bparam-x \"$filename\" sync -n" );
    # Sample output from p4 sync -n
    # //depot/main/Dev/Cyclone/ManagedPVT/PI_FIT-1-0-0/SW/SRC/Cp_src/ChasMgr/src/chmCardDbMsg.c - file(s) up-to-date.
    # //depot/main/Dev/Cyclone/ManagedPVT/PI_FIT-1-0-0/SW/SRC/Cp_src/ChasMgr/src/chmCheckin.c - file(s) up-to-date.
    # //depot/main/Dev/Cyclone/ManagedPVT/PI_FIT-1-0-0/SW/SRC/Cp_src/ChasMgr/src/chmLib.c#28 - is opened and not being changed
    # ... //depot/main/Dev/Cyclone/ManagedPVT/PI_FIT-1-0-0/SW/SRC/Cp_src/ChasMgr/src/chmLib.c - must resolve #28 before submitting
    # //depot/main/Dev/Cyclone/ManagedPVT/PI_FIT-1-0-0/SW/SRC/Cp_src/ChasMgr/src/chmState.c - file(s) up-to-date.
    # //depot/main/Dev/Cyclone/ManagedPVT/PI_FIT-1-0-0/SW/SRC/UsrLib_src/UsrLib_src-S/halCardDef_S.c - file(s) up-to-date.
    #

    # Error out if the user has opened any out-of-date files.
    if (   $checkConflicts =~ m/must\sresolve\s#(\d+)\sbefore\ssubmitting/s)
    {
        $self->cpf_error( "checkForConflicts: "
                . $checkConflicts
                . " Opened files are out of sync with the head. Sync and resolve "
                . "conflicts, then retry the preflight build" );
    }

    # Error out if the user any files pending a merge.
    $checkConflicts = $self->cpf_p4( $opts, "$bparam-x \"$filename\" resolve -n" );
    if (   $checkConflicts !~ m/no\sfile\(s\)\sto\sresolve/s
        && $checkConflicts ne "" )
    {
        $self->cpf_error( "Opened files have conflicts that need to be resolved. Resolve "
                . "conflicts, then retry the preflight build" );
    }

}

#---------------------
# updateOptions
# Update options hash with values stored in configuration
#
# Args:
#   opts  - options passed in from caller
#---------------------
sub updateOptions {
    my ($self, $opts) = @_;

    # add configuration that is stored for this config
    my $name = $self->getCfg()->getName();
    my %row  = $self->getCfg()->getRow($name);
    for my $k ( keys %row ) {
        $self->debug("Reading $k=$row{$k} from config");
        $opts->{$k} = $row{$k};
    }

    # parameter may be passed as xml ref, we convert it back to it's value
    for my $k ( keys %$opts ) {
        if(ref($opts->{$k})) {
            $opts->{$k} = $opts->{$k}->value();
        }
    }
}

1;




