####################################################################
#
# ECSCM::Perforce::Cfg: Object definition of a perforce SCM configuration.
#
####################################################################
package ECSCM::Perforce::Cfg;
@ISA = (ECSCM::Base::Cfg);
if (!defined ECSCM::Base::Cfg) {
    require ECSCM::Base::Cfg;
}

####################################################################
# Object constructor for ECSCM::Perforce::Cfg
#
# Inputs
#   cmdr  = a previously initialized ElectricCommander handle
#   name  = a name for this configuration
####################################################################
sub new {
    my $class = shift;

    my $cmdr = shift;
    my $name = shift;

    my($self) = ECSCM::Base::Cfg->new($cmdr,"$name");
    bless ($self, $class);
    return $self;
}


####################################################################
# P4PORT
####################################################################
sub getP4PORT {
    my ($self) = @_;
    return $self->get("P4PORT");
}
sub setP4PORT {
    my ($self, $name) = @_;
    print "Setting P4PORT to $name\n";
    return $self->set("P4PORT", "$name");
}


####################################################################
# P4TICKETS
####################################################################
sub getP4TICKETS {
    my ($self) = @_;
    return $self->get("P4TICKETS");
}
sub setP4TICKETS {
    my ($self, $name) = @_;
    print "Setting P4TICKETS to $name\n";
    return $self->set("P4TICKETS", "$name");
}

####################################################################
# P4CHARSET
####################################################################
sub getP4CHARSET {
    my ($self) = @_;
    return $self->get("P4CHARSET");
}
sub setP4CHARSET {
    my ($self, $name) = @_;
    print "Setting P4CHARSET to $name\n";
    return $self->set("P4CHARSET", "$name");
}

####################################################################
# P4COMMANDCHARSET
####################################################################
sub getP4COMMANDCHARSET {
    my ($self) = @_;
    return $self->get("P4COMMANDCHARSET");
}
sub setP4COMMANDCHARSET {
    my ($self, $name) = @_;
    print "Setting P4COMMANDCHARSET to $name\n";
    return $self->set("P4COMMANDCHARSET", "$name");
}

####################################################################
# Credential
####################################################################
sub getCredential {
    my ($self) = @_;
    return $self->get("Credential");
}
sub setCredential {
    my ($self, $name) = @_;
    print "Setting Credential to $name\n";
    return $self->set("Credential", "$name");
}


1;
