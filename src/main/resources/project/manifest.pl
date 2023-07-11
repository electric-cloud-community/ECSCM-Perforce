@files = (
    ['//property[propertyName="ECSCM::Perforce::Cfg"]/value', 'PerforceCfg.pm'],
    ['//property[propertyName="ECSCM::Perforce::Driver"]/value', 'PerforceDriver.pm'],   
	['//property[propertyName="checkout"]/value', 'perforceCheckoutForm.xml'],
    ['//property[propertyName="preflight"]/value', 'perforcePreflightForm.xml'],
    ['//property[propertyName="sentry"]/value', 'perforceSentryForm.xml'],
    ['//property[propertyName="trigger"]/value', 'perforceTriggerForm.xml'],
    ['//property[propertyName="createConfig"]/value', 'perforceCreateConfigForm.xml'],
    ['//property[propertyName="editConfig"]/value', 'perforceEditConfigForm.xml'],
    ['//property[propertyName="ec_setup"]/value', 'ec_setup.pl'],
	['//procedure[procedureName="CheckoutCode"]/propertySheet/property[propertyName="ec_parameterForm"]/value', 'perforceCheckoutForm.xml'],
	['//procedure[procedureName="Preflight"]/propertySheet/property[propertyName="ec_parameterForm"]/value', 'perforcePreflightForm.xml'],
);
