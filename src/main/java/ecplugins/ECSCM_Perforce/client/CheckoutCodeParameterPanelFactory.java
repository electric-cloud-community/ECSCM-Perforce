// CheckoutCodeParameterPanelFactory.java --
//
// CheckoutCodeParameterPanelFactory.java is part of ElectricCommander.
//
// Copyright (c) 2005-2011 Electric Cloud, Inc.
// All rights reserved.
//

package ecplugins.ECSCM_Perforce.client;

import com.electriccloud.commander.gwt.client.Component;
import com.electriccloud.commander.gwt.client.ComponentContext;

import ecinternal.client.InternalComponentBaseFactory;
import org.jetbrains.annotations.NotNull;


/**
 * This factory is responsible for providing instances of the
 * CheckoutCodeParameterPanel class.
 */
public class CheckoutCodeParameterPanelFactory
    extends InternalComponentBaseFactory {

    @NotNull
    @Override public Component createComponent(ComponentContext jso) {
        return new CheckoutCodeParameterPanel();
    }
}
