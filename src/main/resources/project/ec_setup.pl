no warnings 'redefine';

my $projPrincipal = "project: $pluginName";
my $ecscmProj = '$[/plugins/ECSCM/project]';

ElectricUpgrader::on_upgrade($upgradeAction);

if ($promoteAction eq 'promote') {
    # Register our SCM type with ECSCM
    $batch->setProperty("/plugins/ECSCM/project/scm_types/@PLUGIN_KEY@", "Perforce");
    
    # Give our project principal execute access to the ECSCM project
    my $xpath = $commander->getAclEntry("user", $projPrincipal,
                                        {projectName => $ecscmProj});
    if ($xpath->findvalue('//code') eq 'NoSuchAclEntry') {
        $batch->createAclEntry("user", $projPrincipal,
                               {projectName => $ecscmProj,
                                executePrivilege => "allow"});
    }

    # Modify parameters in the Preflight steps.

    my $ret = $commander->findObjects("procedureStep", {
            filter => [
                {
                    propertyName => "subproject",
                    operator => "equals",
                    operand1 => "/plugins/ECSCM-Perforce/project"
                },
                {
                    propertyName => "subprocedure",
                    operator => "equals",
                    operand1 => "Preflight"
                }
            ]
        }
    );

    foreach my $step ($ret->findnodes("//step")) {
        my $projectName = $step->findvalue("projectName");
        my $procedureName = $step->findvalue("procedureName");
        my $stepName = $step->findvalue("stepName");

        # Delete the defunct actual parameter "client" which was removed
        # sometime after version 1.1.19.

        $batch->deleteActualParameter($projectName, $procedureName, $stepName,
            "client");
    }

    # Modify parameters in the CheckoutCode steps.

    $ret = $commander->findObjects("procedureStep", {
        filter => [
        {
            propertyName => "subproject",
            operator => "equals",
            operand1 => "/plugins/ECSCM-Perforce/project"
        },
        {
            propertyName => "subprocedure",
            operator => "equals",
            operand1 => "CheckoutCode"
        }]});

    foreach my $step ($ret->findnodes("//step")) {
        my $projectName = $step->findvalue("projectName");
        my $procedureName = $step->findvalue("procedureName");
        my $stepName = $step->findvalue("stepName");

        # Delete the defunct actual parameter "refreshTemplateClient", which was
        # removed in version 2.7.  We need to delete steps which already have it
        # so they don't cause a parameter mismatch.

        $batch->deleteActualParameter($projectName, $procedureName, $stepName,
            "refreshTemplateClient");

        my $previousAbort = $commander->abortOnError();
        $commander->abortOnError(0);

        # Modify the actual parameter "forceSync" to "forcedSync" since it was
        # renamed somewhere between 1.1.19 and 2.7.1.

        my $result = $commander->getActualParameter("forceSync", {
            projectName => $projectName,
            procedureName => $procedureName,
            stepName => $stepName
        });
        if ($result->exists("//actualParameterName")) {
            $batch->modifyActualParameter($projectName, $procedureName,
                $stepName, "forceSync", {newName => "forcedSync"});
        }

        # Modify the actual parameter "incremental" to "retainTemplateClient"
        # since it was renamed somewhere between 1.1.19 and 2.7.1.

        $result = $commander->getActualParameter("incremental", {
            projectName => $projectName,
            procedureName => $procedureName,
            stepName => $stepName
        });
        if ($result->exists("//actualParameterName")) {
            $batch->modifyActualParameter($projectName, $procedureName,
                $stepName, "incremental", {newName => "retainTemplateClient"});
        }

        # If template is set and neither smartSync nor standardSync are set,
        # default to standardSync.

        my $template = $commander->getActualParameter("template", {
            projectName => $projectName,
            procedureName => $procedureName,
            stepName => $stepName
        })->findvalue("//actualParameterName");

        my $smartSync = $commander->getActualParameter("smartSync", {
            projectName => $projectName,
            procedureName => $procedureName,
            stepName => $stepName
        })->findvalue("//actualParameterName");

        my $standardSync = $commander->getActualParameter("standardSync", {
            projectName => $projectName,
            procedureName => $procedureName,
            stepName => $stepName
        })->findvalue("//actualParameterName");

        if ($template ne "" && ($smartSync eq "" && $standardSync eq "")) {
            $batch->modifyActualParameter($projectName, $procedureName,
                $stepName, "standardSync", {value => "1"});
        }

        # If it exists, move the value of the "client" parameter to a property
        # on the step so it will be picked up and used by the CheckoutCode
        # instead of defaulting to our chosen path.

        $result = $commander->getActualParameter("client", {
            projectName => $projectName,
            procedureName => $procedureName,
            stepName => $stepName
        });
        if ($result->exists("//actualParameterName")) {
            $batch->setProperty("/projects/$projectName/procedures/$procedureName"
                . "/steps/$stepName/ec_clientName",
                $result->findvalue("//value")->string_value,
                {
                    description => "Preserved during ECSCM-Perforce upgrade; "
                        . "will override other client name settings."
                });
            $batch->deleteActualParameter($projectName, $procedureName, $stepName,
                "client");
        }

        $commander->abortOnError($previousAbort);
    }

} elsif ($promoteAction eq 'demote') {
    # unregister with ECSCM
    $batch->deleteProperty("/plugins/ECSCM/project/scm_types/@PLUGIN_KEY@");
    
    # remove permissions
    my $xpath = $commander->getAclEntry("user", $projPrincipal,
                                        {projectName => $ecscmProj});
    if ($xpath->findvalue('//principalName') eq $projPrincipal) {
        $batch->deleteAclEntry("user", $projPrincipal,
                               {projectName => $ecscmProj});
    }
}

# Unregister current and past entries first.
$batch->deleteProperty("/server/ec_customEditors/pickerStep/ECSCM-Perforce - Checkout");
$batch->deleteProperty("/server/ec_customEditors/pickerStep/ECSCM-Perforce - Preflight");
$batch->deleteProperty("/server/ec_customEditors/pickerStep/Perforce - Checkout");
$batch->deleteProperty("/server/ec_customEditors/pickerStep/Perforce - Preflight");

my %Checkout = (
    label       => "Perforce - Checkout",
    procedure   => "CheckoutCode",
    description => "Checkout code from Perforce.",
    category    => "Source Code Management"
);

my %Preflight = (
    label => "Perforce - Preflight",
    procedure => "Preflight",
    description => "Checkout code from Perforce during Preflight.",
    category => "Source Code Management"
);


@::createStepPickerSteps = (\%Checkout, \%Preflight);


package ElectricUpgrader;

sub on_upgrade {
    my ($action) = @_;

    return 1 if $action ne 'upgrade';

    my $commander = ElectricCommander->new();
    my $steps = $commander->findObjects("procedureStep", {
        filter => [
            {
                propertyName => "subproject",
                operator     => "equals",
                operand1     => "/plugins/ECSCM-Perforce/project"
            },
            {
                propertyName => "subprocedure",
                operator     => "equals",
                operand1     => "CheckoutCode"
            }
        ]
    });

    for my $step ($steps->findnodes("//step")) {
        my $projectName = $step->findvalue("projectName");
        my $procedureName = $step->findvalue("procedureName");
        my $stepName = $step->findvalue("stepName");

        my $parameters = $commander->getActualParameters({
            projectName     => $projectName,
            procedureName   => $procedureName,
            stepName        => $stepName}
        );

        my $propertiesExists = 0;
        my $propsExists = 0;
        my $value;

        my $step_params = {};

        for my $parameter ($parameters->findnodes('//actualParameter')) {
            my $name = $parameter->findvalue('actualParameterName');
            my $value = $parameter->findvalue('value');
            $step_params->{$name} = $value;
        }
        # key doesn't exists, so, plugin is old, and we going to create this property
        # for compatibility
        if (!exists $step_params->{generateChangelog}) {
            $step_params->{generateChangelog} = 1;
            $commander->createActualParameter(
                $projectName,
                $procedureName,
                $stepName,
                "generateChangelog",
                { value => 1 }
            );
        }
        
        if ($step_params->{generateChangelog} && !$step_params->{updatesFile}) {
            my $new_filename = q|Changelog-$[jobStepId]|;
            eval {
                $commander->deleteActualParameter($projectName, $procedureName, $stepName, "updatesFile");
            };
            eval {
                $commander->createActualParameter(
                    $projectName,
                    $procedureName,
                    $stepName,
                    "updatesFile",
                    { value => $new_filename }
                );
            };
        }
    }

}
