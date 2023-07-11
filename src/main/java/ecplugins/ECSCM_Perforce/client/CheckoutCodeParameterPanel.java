
// CheckoutCodeParameterPanel.java --
//
// CheckoutCodeParameterPanel.java is part of ElectricCommander.
//
// Copyright (c) 2005-2014 Electric Cloud, Inc.
// All rights reserved.
//

package ecplugins.ECSCM_Perforce.client;

import java.util.Arrays;
import java.util.Collection;
import java.util.HashMap;
import java.util.Map;

import com.google.gwt.core.client.GWT;
import com.google.gwt.event.logical.shared.ValueChangeEvent;
import com.google.gwt.event.logical.shared.ValueChangeHandler;
import com.google.gwt.uibinder.client.UiBinder;
import com.google.gwt.uibinder.client.UiFactory;
import com.google.gwt.uibinder.client.UiField;
import com.google.gwt.user.client.ui.TextArea;
import com.google.gwt.user.client.ui.TextBox;
import com.google.gwt.user.client.ui.Widget;

import com.electriccloud.commander.client.domain.ActualParameter;
import com.electriccloud.commander.client.domain.FormalParameter;
import com.electriccloud.commander.client.util.StringUtil;
import com.electriccloud.commander.gwt.client.ComponentBase;
import com.electriccloud.commander.gwt.client.ui.CustomValueCheckBox;
import com.electriccloud.commander.gwt.client.ui.FormBuilder;
import com.electriccloud.commander.gwt.client.ui.ParameterPanel;
import com.electriccloud.commander.gwt.client.ui.ParameterPanelProvider;
import com.electriccloud.commander.gwt.client.ui.ValuedListBox;

/**
 * A Parameter Panel that makes it easy and logical for users to specify the set
 * of parameters necessary for a Perforce Checkout.
 */
public class CheckoutCodeParameterPanel
    extends ComponentBase
    implements ParameterPanel,
        ParameterPanelProvider
{

    //~ Static fields/initializers ---------------------------------------------

    private static UiBinder<Widget, CheckoutCodeParameterPanel> s_binder = GWT
            .create(Binder.class);

    // Use constants for the widget identifier names
    static final String SOURCETYPE_ID    = "sourceType";
    static final String SYNCTYPE_ID      = "syncType";
    static final String CONFIGURATION_ID = "config";
    static final String DEST_ID          = "dest";
    static final String CHANGELIST_ID    = "changelist";
    static final String LASTSNAPSHOT_ID  = "lastSnapshot";
    static final String UPDATESFILE_ID   = "updatesFile";

    // static final String CLIENTNAMEPREFIX_ID = "clientNamePrefix";
    static final String CHECKOUTSINGLEFILE_ID = "checkoutSingleFile";
    static final String FORCEDSYNC_ID         = "forcedSync";
    static final String PARALLELSYNC_ID       = "parallelSync";
    static final String RETAINTMPLCLIENT_ID   = "retainTemplateClient";

    // bhandley - remove this parameter. It doesn't get used for anything
    // since retained clients are always refreshed
    // static final String REFRESHTMPLCLIENT_ID  = "refreshTemplateClient";
    static final String SMARTSYNC_ID    = "smartSync";
    static final String STANDARDSYNC_ID = "standardSync";
    static final String DELETEFILES_ID  = "deleteFiles";
    static final String AUTOLOGIN_ID    = "autoLogin";

    // static final String CLIENT_ID = "client";
    static final String TEMPLATE_ID = "template";
    static final String STREAM_ID   = "stream";
    static final String BRANCH_ID   = "branch";
    static final String VIEW_ID     = "view";

    // HEC - added for Riot Games
    static final String UNIQUEWORKSPACE_ID    = "prefix";
    static final String POSTFIX_ID            = "postfix";
    static final String ALLWRITE_ID           = "allwrite";
    static final String CLOBBER_ID            = "clobber";
    static final String COMPRESS_ID           = "compress";
    static final String LOCKED_ID             = "locked";
    static final String MODTIME_ID            = "modtime";
    static final String RMDIR_ID              = "rmdir";
    static final String CLEAN_ID              = "clean";
    static final String CHANGELISTNUMS_ID     = "unshelveCLs";
    static final String REPORTONLY_ID         = "reportOnly";
    static final String GENERATE_CHANGELOG_ID = "generateChangelog";

    //~ Instance fields --------------------------------------------------------

    // The actual form we are going to use will be instantiated at runtime via
    // dependency injection, so there is no need for a 'new' or Factory in our
    // code.
    @UiField FormBuilder coParameterForm;

    // This map lets us record which fields are relevant (or not) to return
    // based on the situation of the form. We update this while resetting field
    // visibility.
    private Map<String, Boolean> m_detailIsRelevant = new HashMap<String,
            Boolean>();

    //~ Methods ----------------------------------------------------------------

    /**
     * This function is called by SDK infrastructure to initialize the UI parts
     * of this component. Add the parameter field form elements here, along with
     * handlers where needed.
     *
     * @return  A widget that the infrastructure should place in the UI; usually
     *          a panel.
     */
    @Override public Widget doInit()
    {
        Widget base = s_binder.createAndBindUi(this);

        coParameterForm.addRow(true, "Configuration:",
            "The name of an existing Electric Commander ECSCM configuration. Use the 'Administration / Source Control' tab to create and manage these.",
            CONFIGURATION_ID, "default", new TextBox());

        // This is a selection list box (a 'ValuedListBox'), for the 'type' of
        // the source location. This will determine characteristics of some of
        // the other parameter attributes, particularly precisely where the
        // actual source is found. NOTE: To make the mechanics easier, the value
        // of the list item is the ID of the associated source parameter widget.
        // HEC - change order to template, view, branch, stream
        final ValuedListBox sourceTypeLB = getUIFactory().createValuedListBox();

        sourceTypeLB.addItem("Client Template", TEMPLATE_ID);
        sourceTypeLB.addItem("Explicit View Spec", VIEW_ID);
        sourceTypeLB.addItem("Branch", BRANCH_ID);
        sourceTypeLB.addItem("Stream", STREAM_ID);

//        sourceTypeLB.addItem("Existing Client", CLIENT_ID);
        // Set the values of source spec parameter(s) depending on this value.
        sourceTypeLB.addValueChangeHandler(new ValueChangeHandler<String>() {
                @Override public void onValueChange(
                        ValueChangeEvent<String> event)
                {
                    updateRowVisibility();
                }
            });

        // This is a selection list box (a 'ValuedListBox'), for the 'type' of
        // the synchronization.
        final ValuedListBox syncTypeLB = getUIFactory().createValuedListBox();

        syncTypeLB.addItem("Standard Sync", STANDARDSYNC_ID);
        syncTypeLB.addItem("Smart Sync", SMARTSYNC_ID);

        // Show only the appropriate sync-type parameter(s) depending on this
        // value.
        syncTypeLB.addValueChangeHandler(new ValueChangeHandler<String>() {
                @Override public void onValueChange(
                        ValueChangeEvent<String> event)
                {
                    updateRowVisibility();
                }
            });
        coParameterForm.addRow(true, "Source Type:",
            "Select the type of repository source location specification.",
            SOURCETYPE_ID, TEMPLATE_ID, sourceTypeLB);

        // HEC - make Standard Sync the default Sync Type
        coParameterForm.addRow(true, "Sync Type:",
            "Select the type of synchronization.", SYNCTYPE_ID, STANDARDSYNC_ID,
            syncTypeLB);
        coParameterForm.addRow(false, "Client Template:",
            "The name of an existing Perforce client to use as a template; the view spec will be copied to a temporary client for the duration of the build.",
            TEMPLATE_ID, "", new TextBox());
        coParameterForm.addRow(false, "Stream:",
            "An existing Stream to be used as the template for the temporary client.",
            STREAM_ID, "", new TextBox());
        coParameterForm.addRow(false, "Branch:",
            "A depot path representing a branch.", BRANCH_ID, "",
            new TextBox());
        coParameterForm.addRow(false, "View:",
            "An explicit client view specification to be used as the template for the temporary client. The depot and file paths must be specified in standard view format. However, the depot and file specification on each line must be separated by a semicolon instead of a space.",
            VIEW_ID, "", new TextArea());
        // HEC - changes for RIOT games

        // adding the six options presented through the p4v interface
        // for creating a new workspace
        final CustomValueCheckBox allwriteCheckbox = getUIFactory()
                .createCustomValueCheckBox("1", "0");
        final CustomValueCheckBox clobberCheckbox  = getUIFactory()
                .createCustomValueCheckBox("1", "0");
        final CustomValueCheckBox compressCheckbox = getUIFactory()
                .createCustomValueCheckBox("1", "0");
        final CustomValueCheckBox lockedCheckbox   = getUIFactory()
                .createCustomValueCheckBox("1", "0");
        final CustomValueCheckBox modtimeCheckbox  = getUIFactory()
                .createCustomValueCheckBox("1", "0");
        final CustomValueCheckBox rmdirCheckbox    = getUIFactory()
                .createCustomValueCheckBox("1", "0");

        coParameterForm.addRow(false, "allwrite:",
            "Will all files be writable in the workspace, or only files that have been opened for edit?",
            ALLWRITE_ID, "", allwriteCheckbox);
        coParameterForm.addRow(false, "clobber:",
            "Should the sync command overwrite any writable, unopened files? The default value is off. If you turn this option on, any writable, unopened files in your workspace can be overwritten when you run sync. This includes files made writable either either from using the allwrite option described above, or by manually changing permissions from within your local operating system.",
            CLOBBER_ID, "", clobberCheckbox);
        coParameterForm.addRow(false, "compress:",
            "Will data sent between your client workspace and the Perforce server be compressed? The default value is off. Over a LAN or high-bandwidth connection, there's little benefit to compressing this data, but if you're operating over a slow link, turning this option on will help.",
            COMPRESS_ID, "", compressCheckbox);
        coParameterForm.addRow(false, "locked:",
            "Lock the client spec? The default value is off (unlocked). Anyone can use the workspace or edit the client spec. If you turn this on, only the user shown in the Owner field will be able to use the workspace or edit the specification.",
            LOCKED_ID, "", lockedCheckbox);
        coParameterForm.addRow(false, "modtime:",
            "What should the modification time on files in your workspace be set to when copied in by the sync command? By default, the modification time of unopened files on your workspace files shows when they were synced. Choosing this option will cause sync to set each file's modification time to the timestamp associated with it when it was submitted to the depot.",
            MODTIME_ID, "", modtimeCheckbox);
        coParameterForm.addRow(false, "rmdir:",
            "Should a sync command that deletes all files in a directory also delete the directory? The default value is off. A sync command that removes all files in a directory will leave empty directories. If you turn this option on, empty directories will be removed.",
            RMDIR_ID, "", rmdirCheckbox);

        // Unique Workspace Identifier
        coParameterForm.addRow(false, "Unique Workspace Identifier:",
            "Used as a prefix to construct the new Workspace name. \nShould be unique for the system.  If changed after a prior run, the connection between the previously-created Workspace and this sync operation will be broken resulting in a full sync.",
            UNIQUEWORKSPACE_ID, "", new TextBox());

        // postfix for the name of the Workspace that will be created.
        coParameterForm.addRow(false, "Workspace Name Postfix:",
            "A string to append to the name of the Workspace that will be created.",
            POSTFIX_ID, "", new TextBox());
        coParameterForm.addRow(false, "Destination Directory:",
            "The location into which the source is checked out (Default: job workspace root). Required when Client Template, Standard Sync, and Retain Client are all enabled.",
            DEST_ID, "", new TextBox());

        // HEC - changed help text to indicate that a Perforce label can also
        // be specified here
        coParameterForm.addRow(false, "Changelist (or Label):",
            "A specific changelist number OR a Perforce label. The string 'have' (uses the workspace template), or blank (default, the most recent changelist).",
            CHANGELIST_ID, "", new TextBox());

        final CustomValueCheckBox changelogCheckbox = getUIFactory()
                .createCustomValueCheckBox("1", "0");
        changelogCheckbox.setInitiallyChecked(true);
        
        coParameterForm.addRow(false, "Generate changelog report:",
            "Generate changelog report on checkout step", GENERATE_CHANGELOG_ID,
            "", changelogCheckbox);
        coParameterForm.addRow(false, "Last Snapshot:",
            "The start point for update log. Next changelist will be included in the update log",
            LASTSNAPSHOT_ID, "", new TextBox());
        coParameterForm.addRow(false, "Updates File:",
            "The name of a file to be written with the text change comments of all changes included in this checkout since the 'Last Snapshot'.",
            UPDATESFILE_ID, "", new TextBox());

        final ParallelSyncOptions parallelSyncOptions = new ParallelSyncOptions(
                "threads=10");

        coParameterForm.addRow(false, "Parallel Sync:",
            "Enable parallel sync option, requires server version 2014.1 or later.",
            PARALLELSYNC_ID, "", parallelSyncOptions);

        final CustomValueCheckBox forcedCheckbox = getUIFactory()
                .createCustomValueCheckBox("1", "0");

        coParameterForm.addRow(false, "Forced Sync:",
            "Perforce performs a full sync (using p4 sync -f), copying every file in the View. For Standard Sync only.",
            FORCEDSYNC_ID, "", forcedCheckbox);

        // HEC - allow user to specify to clean the local workspace
        final CustomValueCheckBox cleanCheckbox = getUIFactory()
                .createCustomValueCheckBox("1", "0");

        coParameterForm.addRow(false, "Clean Local Workspace:",
            "Clean the local workspace, and perform a full sync", CLEAN_ID, "",
            cleanCheckbox);

        // bhandley - remove this parameter and UI element. It doesn't do
        // anything in the driver code final CustomValueCheckBox
        // refreshClientFromTemplateCheckbox =
        // getUIFactory().createCustomValueCheckBox("1", "0"); HEC - change
        // label from "Refresh Client from Template" to "Refresh Workspace from
        // Template coParameterForm.addRow(false, "Refresh Workspace from
        // Template:", "Refresh client view from named Template before sync; use
        // when Template has been changed. Client Template source only.",
        // REFRESHTMPLCLIENT_ID, "", refreshClientFromTemplateCheckbox);
        final CustomValueCheckBox retainClientCheckbox = getUIFactory()
                .createCustomValueCheckBox("1", "0");

        coParameterForm.addRow(false, "Retain Client:",
            "Do not delete the client after the sync. Client Template source with Standard Sync only.",
            RETAINTMPLCLIENT_ID, "", retainClientCheckbox);
        retainClientCheckbox.addValueChangeHandler(
            new ValueChangeHandler<String>() {
                @Override public void onValueChange(
                        ValueChangeEvent<String> event)
                {
                    updateRowVisibility();
                }
            });

        final CustomValueCheckBox checkoutSingleFileCheckbox = getUIFactory()
                .createCustomValueCheckBox("1", "0");

        coParameterForm.addRow(false, "Checkout Individual Files:",
            "Checkout only specific files instead of assuming an entire directory. (Does not automatically add '...' wildcard to paths on the View parameter.)",
            CHECKOUTSINGLEFILE_ID, "", checkoutSingleFileCheckbox);

        /**
         * TODO: Set the sync-type listbox value on startup based on the checkboxes
         * TODO: The list box should set the return value to the procedure.
         * TODO: Add code so that existing parameters get fixed in ec_setup.
         */
        final CustomValueCheckBox deleteFilesCheckbox = getUIFactory()
                .createCustomValueCheckBox("1", "0");

        coParameterForm.addRow(false, "Delete untracked files:",
            "During a Smart Sync, do not delete files that are not found in the Perforce repository.",
            DELETEFILES_ID, "", deleteFilesCheckbox);

        final CustomValueCheckBox autoLoginCheckbox = getUIFactory()
                .createCustomValueCheckBox("1", "0");

        coParameterForm.addRow(false, "Automatic Ticket Login/Logout:",
            "If checked it uses the P4TICKETS authentication form rather than user/password.",
            AUTOLOGIN_ID, "", autoLoginCheckbox);

        // HEC - add UI element to capture changelist numbers
        coParameterForm.addRow(true, "Unshelve CLs:",
            "Enter a list (one per line) of Change List #s to unshelve",
            CHANGELISTNUMS_ID, "", new TextArea());

        // HEC - Don't Sync, Report Only
        final CustomValueCheckBox reportOnlyCheckbox = getUIFactory()
                .createCustomValueCheckBox("1", "0");

        coParameterForm.addRow(true, "Report Only:",
            "This will cause the plugin to NOT actually execute the sync operation. Instead, it will do all of the changes/updates calculations and generate all the same reports and send the same emails, as if a sync had been done.",
            REPORTONLY_ID, "", reportOnlyCheckbox);

        // Update the details panel row visibilities.
        updateRowVisibility();

        return base;
    }

    @Override public boolean validate()
    {

        // After submit, validate specific inter-parameter conditions. First let
        // the form check itself; as of now checks for required params and
        // credential password match.
        boolean validationStatus = coParameterForm.validate();

        return validationStatus;
    }

    /**
     * The dynamic aspect of the panel is implemented here. By setting the
     * visibility and 'requiredness' of various rows in the form, it will morph
     * to make the usage safer and easier.
     */
    protected void updateRowVisibility()
    {

        // This loop sets the simple cases (visible, not required, and
        // relevant), anything more complex should be taken out of here and
        // handled as necessary.
        for (String key : new String[] {
                    DEST_ID,
                    CHANGELIST_ID,
                    LASTSNAPSHOT_ID,
                    UPDATESFILE_ID,
                    DELETEFILES_ID,
                }) {
            coParameterForm.setRowVisible(key, true);
            coParameterForm.setPropertyRequired(key, false);
            m_detailIsRelevant.put(key, true);
        }

        // These values are used below to determine attributes of other widgets
        String syncType     = coParameterForm.getValue(SYNCTYPE_ID);
        String sourceType   = coParameterForm.getValue(SOURCETYPE_ID);
        String retainClient = coParameterForm.getValue(RETAINTMPLCLIENT_ID);

        // The source sourceType determines the visibility of the source
        // parameters Start by hiding all the source parameter widgets and
        // making them irrelevant...
        for (String key : new String[] {
                    TEMPLATE_ID,
                    STREAM_ID,
                    BRANCH_ID,
                    VIEW_ID,
                }) {
            coParameterForm.setRowVisible(key, false);
            coParameterForm.setPropertyRequired(key, false);
            m_detailIsRelevant.put(key, false);
        }

        // ... then show and require the widget that matches the listbox
        // selection
        coParameterForm.setRowVisible(sourceType, true);
        coParameterForm.setPropertyRequired(sourceType, true);
        m_detailIsRelevant.put(sourceType, true);

        // Delete Files checkbox is only relevant when the sync type is Smart
        // Sync
        coParameterForm.setRowVisible(DELETEFILES_ID,
            SMARTSYNC_ID.equals(syncType));
        coParameterForm.setPropertyRequired(DELETEFILES_ID, false); // optional
        m_detailIsRelevant.put(DELETEFILES_ID, SMARTSYNC_ID.equals(syncType));

/*
        // Destination and Client Name Prefix are not used with a sourcetype of 'client'
        coParameterForm.setRowVisible(DEST_ID, !CLIENT_ID.equals(sourceType));
        m_detailIsRelevant.put(DEST_ID, !CLIENT_ID.equals(sourceType));
        coParameterForm.setRowVisible(CLIENTNAMEPREFIX_ID, !CLIENT_ID.equals(sourceType));
        m_detailIsRelevant.put(CLIENTNAMEPREFIX_ID, !CLIENT_ID.equals(sourceType));
*/
        // Forced Sync is only relevant when the sync type is 'Standard'
        coParameterForm.setRowVisible(FORCEDSYNC_ID,
            STANDARDSYNC_ID.equals(syncType));
        coParameterForm.setPropertyRequired(FORCEDSYNC_ID, false); // optional
        m_detailIsRelevant.put(FORCEDSYNC_ID, STANDARDSYNC_ID.equals(syncType));

        // HEC - Clean Local Workspace is relevant when the sync type is
        // 'Standard'
        coParameterForm.setRowVisible(CLEAN_ID,
            STANDARDSYNC_ID.equals(syncType));
        coParameterForm.setPropertyRequired(CLEAN_ID, false); // optional
        m_detailIsRelevant.put(CLEAN_ID, STANDARDSYNC_ID.equals(syncType));

        // HEC - Refresh Client from Template checkbox should be available for
        // Explicit View Spec mode as well as Client Template mode bhandley -
        // remove this checkbox. It doesn't do anything
        // coParameterForm.setRowVisible(REFRESHTMPLCLIENT_ID,
        // (VIEW_ID.equals(sourceType) || TEMPLATE_ID.equals(sourceType)));
        // coParameterForm.setPropertyRequired(REFRESHTMPLCLIENT_ID, false); //
        // optional m_detailIsRelevant.put(REFRESHTMPLCLIENT_ID,
        // (VIEW_ID.equals(sourceType) || TEMPLATE_ID.equals(sourceType))); HEC
        // - Retain Client should be available for Explicit View Spec, mode as
        // well as Client Template mode when the sync type is 'Standard'
        coParameterForm.setRowVisible(RETAINTMPLCLIENT_ID,
            (VIEW_ID.equals(sourceType)
                    || (TEMPLATE_ID.equals(sourceType)
                        && STANDARDSYNC_ID.equals(syncType))));
        coParameterForm.setPropertyRequired(RETAINTMPLCLIENT_ID, false); // optional
        m_detailIsRelevant.put(RETAINTMPLCLIENT_ID,
            (VIEW_ID.equals(sourceType)
                    || (TEMPLATE_ID.equals(sourceType)
                        && STANDARDSYNC_ID.equals(syncType))));

        // Destination is required when the source type is Template, the sync
        // type is Standard, and Retain is checked
        if (TEMPLATE_ID.equals(sourceType) && STANDARDSYNC_ID.equals(syncType)
                && "1".equals(retainClient)) {
            coParameterForm.setPropertyRequired(DEST_ID, true);
        }

        // Single File Checkout is only relevant when the source type is 'View'
        coParameterForm.setRowVisible(CHECKOUTSINGLEFILE_ID,
            VIEW_ID.equals(sourceType));
        coParameterForm.setPropertyRequired(CHECKOUTSINGLEFILE_ID, false); // optional
        m_detailIsRelevant.put(CHECKOUTSINGLEFILE_ID,
            VIEW_ID.equals(sourceType));

        // Configuration is always required.
        coParameterForm.setRowVisible(CONFIGURATION_ID, true);
        coParameterForm.setPropertyRequired(CONFIGURATION_ID, true);
        m_detailIsRelevant.put(CONFIGURATION_ID, true);
        m_detailIsRelevant.put(AUTOLOGIN_ID, true);

        // HEC - added for Riot Games
        // Unique Workspace Identifier should be visible in Explicit View Mode
        coParameterForm.setRowVisible(UNIQUEWORKSPACE_ID,
            VIEW_ID.equals(sourceType));
        coParameterForm.setPropertyRequired(UNIQUEWORKSPACE_ID, false);
        m_detailIsRelevant.put(UNIQUEWORKSPACE_ID, VIEW_ID.equals(sourceType));

        // postfix name field should be displayed in both the Client Template
        // and the Explicit View Spec modes
        coParameterForm.setRowVisible(POSTFIX_ID,
            (TEMPLATE_ID.equals(sourceType) || VIEW_ID.equals(sourceType)));
        coParameterForm.setPropertyRequired(POSTFIX_ID, false);
        m_detailIsRelevant.put(POSTFIX_ID,
            (TEMPLATE_ID.equals(sourceType) || VIEW_ID.equals(sourceType)));

        // These six options (allwrite, clobber, compress, locked, modtimes,
        // rmdir) are only relevant when the source type is 'Explicit View Spec'
        coParameterForm.setRowVisible(ALLWRITE_ID, VIEW_ID.equals(sourceType));
        coParameterForm.setPropertyRequired(ALLWRITE_ID, false);
        m_detailIsRelevant.put(ALLWRITE_ID, VIEW_ID.equals(sourceType));
        coParameterForm.setRowVisible(CLOBBER_ID, VIEW_ID.equals(sourceType));
        coParameterForm.setPropertyRequired(CLOBBER_ID, false);
        m_detailIsRelevant.put(CLOBBER_ID, VIEW_ID.equals(sourceType));
        coParameterForm.setRowVisible(COMPRESS_ID, VIEW_ID.equals(sourceType));
        coParameterForm.setPropertyRequired(COMPRESS_ID, false);
        m_detailIsRelevant.put(COMPRESS_ID, VIEW_ID.equals(sourceType));
        coParameterForm.setRowVisible(LOCKED_ID, VIEW_ID.equals(sourceType));
        coParameterForm.setPropertyRequired(LOCKED_ID, false);
        m_detailIsRelevant.put(LOCKED_ID, VIEW_ID.equals(sourceType));
        coParameterForm.setRowVisible(MODTIME_ID, VIEW_ID.equals(sourceType));
        coParameterForm.setPropertyRequired(MODTIME_ID, false);
        m_detailIsRelevant.put(MODTIME_ID, VIEW_ID.equals(sourceType));
        coParameterForm.setRowVisible(RMDIR_ID, VIEW_ID.equals(sourceType));
        coParameterForm.setPropertyRequired(RMDIR_ID, false);
        m_detailIsRelevant.put(RMDIR_ID, VIEW_ID.equals(sourceType));

        // HEC - changelistNumbers and reportOnly are always visible
        coParameterForm.setRowVisible(CHANGELISTNUMS_ID, true);
        coParameterForm.setPropertyRequired(CHANGELISTNUMS_ID, false);
        m_detailIsRelevant.put(CHANGELISTNUMS_ID, true);
        coParameterForm.setRowVisible(REPORTONLY_ID, true);
        coParameterForm.setPropertyRequired(REPORTONLY_ID, false);
        m_detailIsRelevant.put(REPORTONLY_ID, true);
    }

    /**
     * This method is used by UIBinder to embed the FormBuilder in the UI.
     *
     * @return  a new FormBuilder.
     */
    @UiFactory FormBuilder createFormBuilder()
    {
        return getUIFactory().createFormBuilder();
    }

    @Override public ParameterPanel getParameterPanel()
    {
        return this;
    }

    @Override /**
               * The step editor uses this to get the values after the
               * create/edit is submitted. We only pass back values that we have
               * determined to be relevant given the choices made by the user.
               */ public Map<String, String> getValues()
    {
        Map<String, String> actualParams      = new HashMap<String, String>();
        Map<String, String> detailsFormValues = coParameterForm.getValues();

        for (String key : new String[] {
                    CONFIGURATION_ID,
                    DEST_ID,
                    CHANGELIST_ID,
                    LASTSNAPSHOT_ID,
                    UPDATESFILE_ID,

                    // CLIENTNAMEPREFIX_ID,
                    // REFRESHTMPLCLIENT_ID,
                    RETAINTMPLCLIENT_ID,
                    CHECKOUTSINGLEFILE_ID,
                    PARALLELSYNC_ID,
                    FORCEDSYNC_ID,
                    DELETEFILES_ID,
                    AUTOLOGIN_ID,

                    // bhandley New Params added to form have to be listed
                    // here in order to be written to properties
                    UNIQUEWORKSPACE_ID,
                    POSTFIX_ID,
                    ALLWRITE_ID,
                    CLOBBER_ID,
                    COMPRESS_ID,
                    LOCKED_ID,
                    MODTIME_ID,
                    RMDIR_ID,
                    CLEAN_ID,
                    CHANGELISTNUMS_ID,
                    REPORTONLY_ID,
                    GENERATE_CHANGELOG_ID,
                    TEMPLATE_ID,
                    STREAM_ID,
                    BRANCH_ID,
                    VIEW_ID,
                }) {
            Boolean isRelevant = m_detailIsRelevant.get(key);

            if ((isRelevant == null) || isRelevant) {

                // Either this key is always relevant (and thus not
                // in the relevancy map) or is relevant right now.
                actualParams.put(key, detailsFormValues.get(key));
            }
            else {

                // Not relevant.
                actualParams.put(key, "");
            }

            // The sync-type parameters are set based on the listbox value.
            // First turn them all off, then turn on the selected one
            actualParams.put(SMARTSYNC_ID, "0");
            actualParams.put(STANDARDSYNC_ID, "0");
            actualParams.put(detailsFormValues.get(SYNCTYPE_ID), "1");
        }

        return actualParams;
    }

    /**
     * This method is called to put the values currently stored on the step back
     * into the form for editing.
     *
     * @param  actualParameters  Actual parameters that the step editor expects
     *                           the panel to accommodate.
     */
    @Override public void setActualParameters(
            Collection<ActualParameter> actualParameters)
    {

        if (actualParameters == null) {
            return;
        }

        // First load the parameters into a map. Makes it easier to
        // update the form by querying for various params randomly.
        Map<String, String> params = new HashMap<String, String>();

        for (ActualParameter p : actualParameters) {
            params.put(p.getName(), p.getValue());
        }

        // Do the easy form elements first. NOTE: "template" is last so as it is
        // evaluated below for sourceType if there is no source parameter with a
        // value (as during a create step), it will end up as the default.
        for (String key : new String[] {
                    CONFIGURATION_ID,
                    DEST_ID,
                    CHANGELIST_ID,
                    LASTSNAPSHOT_ID,
                    UPDATESFILE_ID,

                    // CLIENTNAMEPREFIX_ID,
                    // REFRESHTMPLCLIENT_ID,
                    RETAINTMPLCLIENT_ID,
                    CHECKOUTSINGLEFILE_ID,
                    PARALLELSYNC_ID,
                    FORCEDSYNC_ID,
                    DELETEFILES_ID,
                    AUTOLOGIN_ID,

                    // bhandley New Params added to form have to be listed
                    // here in order to be written to properties
                    UNIQUEWORKSPACE_ID,
                    POSTFIX_ID,
                    ALLWRITE_ID,
                    CLOBBER_ID,
                    COMPRESS_ID,
                    LOCKED_ID,
                    MODTIME_ID,
                    RMDIR_ID,
                    CLEAN_ID,
                    CHANGELISTNUMS_ID,
                    REPORTONLY_ID,
                    GENERATE_CHANGELOG_ID,
                    TEMPLATE_ID,
                    STREAM_ID,
                    BRANCH_ID,
                    VIEW_ID,
                }) {

            // We need to initially set the source type listbox based on which
            // of the source fields has a value. This mechanism will use the
            // last it finds if there are multiple, which would be a mistake
            // (but forgivable).
            if (Arrays.asList(

                              // CLIENT_ID,
                              TEMPLATE_ID, STREAM_ID, BRANCH_ID, VIEW_ID)
                      .contains(key)
                    && (!StringUtil.isEmpty(params.get(key)))) {
                coParameterForm.setValue(SOURCETYPE_ID, key);
            }

            coParameterForm.setValue(key,
                StringUtil.nullToEmpty(params.get(key)));
        }

        // Kind of brute force
        for (String synctypekey : new String[] {
                    STANDARDSYNC_ID,
                    SMARTSYNC_ID,
                }) {

            if ("1".equals(params.get(synctypekey))) {
                coParameterForm.setValue(SYNCTYPE_ID, synctypekey);
            }
        }

        updateRowVisibility();
    }

    @Override public void setFormalParameters(
            Collection<FormalParameter> formalParameters) { }

    //~ Inner Interfaces -------------------------------------------------------

    interface Binder
        extends UiBinder<Widget, CheckoutCodeParameterPanel> { }
}
