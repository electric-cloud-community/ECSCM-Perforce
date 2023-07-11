
// ParallelSyncOptions.java --
//
// ParallelSyncOptions.java is part of ElectricCommander.
//
// Copyright (c) 2005-2014 Electric Cloud, Inc.
// All rights reserved.
//

package ecplugins.ECSCM_Perforce.client;

import com.google.gwt.event.logical.shared.ValueChangeEvent;
import com.google.gwt.event.logical.shared.ValueChangeHandler;
import com.google.gwt.event.shared.HandlerRegistration;
import com.google.gwt.user.client.ui.CheckBox;
import com.google.gwt.user.client.ui.HasValue;
import com.google.gwt.user.client.ui.HorizontalPanel;
import com.google.gwt.user.client.ui.TextBox;

import com.electriccloud.commander.client.util.StringUtil;

public class ParallelSyncOptions
    extends HorizontalPanel
    implements HasValue<String>
{

    //~ Instance fields --------------------------------------------------------

    // ~ Instance fields
    // --------------------------------------------------------
    final CheckBox m_checkbox;
    final TextBox  m_options;
    String         m_defaultOptions;

    //~ Constructors -----------------------------------------------------------

    // ~ Constructors
    // -----------------------------------------------------------
    public ParallelSyncOptions(String defaultOptions)
    {
        super();
        setVerticalAlignment(ALIGN_MIDDLE);
        m_defaultOptions = defaultOptions;
        m_checkbox       = new CheckBox();
        m_options        = new TextBox();

        m_options.setWidth("15em");
        m_checkbox.addValueChangeHandler(new ValueChangeHandler<Boolean>() {
                @Override public void onValueChange(
                        ValueChangeEvent<Boolean> e)
                {
                    m_options.setEnabled(e.getValue());
                }
            });
        add(m_checkbox);
        add(m_options);

        if (!StringUtil.isEmpty(m_defaultOptions)) {
            setValue(m_defaultOptions);
        }

        // Disabled by default
        m_checkbox.setValue(false, true);
    }

    //~ Methods ----------------------------------------------------------------

    // ~ Methods
    // ----------------------------------------------------------------
    @Override public HandlerRegistration addValueChangeHandler(
            ValueChangeHandler<String> handler)
    {
        return addHandler(handler, ValueChangeEvent.getType());
    }

    @Override public String getValue()
    {

        if (m_checkbox.getValue()) {
            return m_options.getValue();
        }

        return "";
    }

    @Override public void setValue(String value)
    {
        setValue(value, false);
    }

    @Override public void setValue(
            String  value,
            boolean fireEvents)
    {

        if (!StringUtil.isEmpty(value)) {
            m_checkbox.setValue(true, true);
            m_options.setValue(value);
        }
        else {
            m_checkbox.setValue(false, true);
        }
    }
}
