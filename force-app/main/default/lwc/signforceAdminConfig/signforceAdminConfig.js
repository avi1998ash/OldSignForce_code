import { LightningElement, track, wire } from 'lwc';
import { getRecord } from 'lightning/uiRecordApi';
import USER_ID from '@salesforce/user/Id';
import USER_NAME from '@salesforce/schema/User.Name';
import USER_EMAIL from '@salesforce/schema/User.Email';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { loadStyle } from 'lightning/platformResourceLoader';
import CHROME_CSS from '@salesforce/resourceUrl/signforceAdminChrome';
import DRIVE_LOGO from '@salesforce/resourceUrl/Drive_Logo';
import ONEDRIVE_LOGO from '@salesforce/resourceUrl/OneDrive_Logo';
import getConfig from '@salesforce/apex/SignForceAdminConfigController.getConfig';
import saveConfig from '@salesforce/apex/SignForceAdminConfigController.saveConfig';
import getSites from '@salesforce/apex/SignForceAdminConfigController.getSites';
import getOrgWideEmails from '@salesforce/apex/SignForceAdminConfigController.getOrgWideEmails';
import getPermissionSetStatus from '@salesforce/apex/SignForceAdminConfigController.getPermissionSetStatus';
import hasAdminAccess from '@salesforce/apex/SignForceAdminConfigController.hasAdminAccess';
import getInternalUsers from '@salesforce/apex/SignForceAdminConfigController.getInternalUsers';
import getCommunityUsers from '@salesforce/apex/SignForceAdminConfigController.getCommunityUsers';
import getAssignedUserIds from '@salesforce/apex/SignForceAdminConfigController.getAssignedUserIds';
import applyAssignments from '@salesforce/apex/SignForceAdminConfigController.applyAssignments';
import getGuestUsers from '@salesforce/apex/SignForceAdminConfigController.getGuestUsers';
import getAssignedGuestUserIds from '@salesforce/apex/SignForceAdminConfigController.getAssignedGuestUserIds';
import applyGuestAssignments from '@salesforce/apex/SignForceAdminConfigController.applyGuestAssignments';
import getIntegrationConfig from '@salesforce/apex/SignForceAdminConfigController.getIntegrationConfig';
import saveIntegrationConfig from '@salesforce/apex/SignForceAdminConfigController.saveIntegrationConfig';

const TIER_OPTIONS = [
    { label: 'Tier 1 - Salesforce Files', value: 'Tier1' },
    { label: 'Tier 2 - Amazon S3 (standard)', value: 'Tier2' },
    { label: 'Tier 3 - Amazon S3 (large / chunked)', value: 'Tier3' }
];

const TEMPLATE_OPTIONS = [
    { label: 'Build Your Own (LWR)', value: 'Build Your Own (LWR)' },
    { label: 'Microsite (LWR)', value: 'Microsite (LWR)' },
    { label: 'Customer Service', value: 'Customer Service' }
];

const STEP_LABELS = ['Site', 'Sender', 'Internal Users (Permission)', 'Guest Users (Permission)', 'Integrations', 'Review'];
const TOTAL_STEPS = STEP_LABELS.length;
const LARGE_USER_THRESHOLD = 1000;
// Remembers the last wizard step in this browser so reopening the tab lands where
// the admin left off. Per-browser is enough — this is a setup screen, not per-record.
const STEP_STORAGE_KEY = 'signforce.adminConfig.lastStep';
// Persist the locked (saved / read-only) state so a reload keeps showing Edit.
const LOCK_STORAGE_KEY = 'signforce.adminConfig.locked';

export default class SignforceAdminConfig extends LightningElement {
    // ---- wizard state ----
    // true once we confirm the user lacks "Customize Application" — shows the
    // contact-admin screen instead of the wizard.
    @track accessDenied = false;
    @track currentStep = 1;
    totalSteps = TOTAL_STEPS;
    driveLogoUrl = DRIVE_LOGO;
    oneDriveLogoUrl = ONEDRIVE_LOGO;
    // Inline "these inputs are required" warning shown under the step on Continue.
    @track stepError = '';

    // ---- config values ----
    @track signingSiteBaseUrl = '';
    @track portalAccountId = '';
    @track orgWideEmailId = '';
    // 'OrgWide' (default) or 'CurrentUser'. Mirrors Sender_Email_Mode__c.
    @track senderEmailMode = 'OrgWide';
    @track _userName = '';
    @track _userEmail = '';

    // Shown as the example "From" on the send-as-the-user card.
    @wire(getRecord, { recordId: USER_ID, fields: [USER_NAME, USER_EMAIL] })
    wiredCurrentUser({ data }) {
        if (!data || !data.fields) return;
        this._userName = (data.fields.Name && data.fields.Name.value) || '';
        this._userEmail = (data.fields.Email && data.fields.Email.value) || '';
    }
    @track defaultStorageTier = '';
    @track integrationGoogleDriveEnabled = false;
    @track integrationGoogleDriveTarget = '';
    @track integrationOneDriveEnabled = false;
    @track integrationOneDriveTarget = '';
    // Folder display names reported up by the provider cards, for the Review step
    // (show the folder name, not its id).
    @track integrationGoogleDriveTargetName = '';
    @track integrationOneDriveTargetName = '';
    // OAuth app credentials. Not shown in the UI — held only to round-trip them on
    // save (saveIntegrationConfig writes whatever it is sent). The values live in
    // the SignForce_Admin_Config__c custom setting, which wins over the CMT record.
    @track googleClientId = '';
    @track googleClientSecret = '';
    @track oneDriveClientId = '';
    @track oneDriveClientSecret = '';

    // ---- dropdown options ----
    @track siteOptions = [];
    @track owaOptions = [];
    tierOptions = TIER_OPTIONS;

    // ---- site creation script generator ----
    showScriptGen = false;
    showCliModal = false;
    showManualModal = false;
    scriptSiteName = 'eSignforce Portal';
    scriptPrefix = 'sign';
    scriptTemplate = 'Build Your Own (LWR)';
    scriptOrgAlias = '';
    templateOptions = TEMPLATE_OPTIONS;

    // ---- permission sets (dual-listbox) ----
    @track permSetOptions = [];
    // Raw per-permission-set status (label, assignable, assigned count) for Review.
    @track _permSetStatus = [];
    @track guestPermSets = [];
    @track guestPermSetNames = [];
    selectedPermSet = '';
    @track _internalUsers = [];
    @track _guestUsers = [];
    @track assignedUserIds = [];
    @track failures = [];

    // ui state
    loading = true;
    saving = false;
    applying = false;
    isDirty = false;
    // Locked (read-only) after "Save configuration" — step tabs disabled until Edit.
    @track locked = false;

    // Auto-save plumbing (non-reactive).
    _loaded = false;       // gate: no auto-save until the initial load finishes
    _autoSaveTimer = null; // debounce handle
    _savePromise = null;   // serialize all saves through one chain

    connectedCallback() {
        this.applyFullBleed();
        this.loadAll();
    }

    disconnectedCallback() {
        // Remove the body marker so the chrome-hiding CSS stops applying once the
        // admin screen is closed — nothing leaks to other Lightning pages.
        try { document.body.classList.remove('sf-admin-chrome'); } catch (e) { /* ignore */ }
        // Flush a pending debounced auto-save so last-moment changes aren't lost.
        this.flushAutoSave();
    }

    // Make the admin screen full-bleed (no standard page header / gray canvas)
    // on ANY page, including subscriber orgs. The body marker scopes the global
    // stylesheet so it only takes effect while this component is mounted.
    applyFullBleed() {
        try { document.body.classList.add('sf-admin-chrome'); } catch (e) { /* ignore */ }
        loadStyle(this, CHROME_CSS).catch(() => { /* non-fatal: :host bg still applies */ });
    }
    async loadAll() {
        this.loading = true;

        // Gate the whole wizard on admin access. Every Apex entry point requires
        // "Customize Application"; without it, show a contact-admin screen instead
        // of loading a wizard that would only error out.
        try {
            const ok = await hasAdminAccess();
            if (!ok) {
                this.accessDenied = true;
                this.loading = false;
                return;
            }
        } catch (e) {
            this.accessDenied = true;
            this.loading = false;
            return;
        }

        const [cfgR, sitesR, owaR, statusR, usersR, guestR, intR] = await Promise.allSettled([
            getConfig(),
            getSites(),
            getOrgWideEmails(),
            getPermissionSetStatus(),
            getInternalUsers(),
            getGuestUsers(),
            getIntegrationConfig()
        ]);

        let alreadyConfigured = false;
        if (cfgR.status === 'fulfilled' && cfgR.value) {
            const cfg = cfgR.value;
            this.signingSiteBaseUrl = cfg.signingSiteBaseUrl || '';
            this.portalAccountId = cfg.portalAccountId || '';
            this.orgWideEmailId = cfg.orgWideEmailId || '';
            this.senderEmailMode = cfg.senderEmailMode || 'OrgWide';
            this.defaultStorageTier = cfg.defaultStorageTier || '';
            alreadyConfigured = !!this.signingSiteBaseUrl;
        }
        if (sitesR.status === 'fulfilled') this.siteOptions = sitesR.value || [];
        if (owaR.status === 'fulfilled') this.owaOptions = owaR.value || [];
        if (usersR.status === 'fulfilled') this._internalUsers = usersR.value || [];
        if (guestR.status === 'fulfilled') this._guestUsers = guestR.value || [];
        if (statusR.status === 'fulfilled') {
            const list = statusR.value || [];
            this._permSetStatus = list;
            const internal = list.filter((p) => p.assignable)
                .map((p) => ({ label: p.label, value: p.name }));
            const guest = list.filter((p) => !p.assignable)
                .map((p) => ({ label: p.label + ' (Guest User)', value: p.name }));
            this.permSetOptions = internal.concat(guest);
            this.guestPermSets = list.filter((p) => !p.assignable);
            this.guestPermSetNames = this.guestPermSets.map((p) => p.name);
            if (this.permSetOptions.length) {
                // Land on the role tabs' default: Admin when the admin permission
                // set exists (newer package versions), else Standard.
                const hasAdmin = this.permSetOptions.some((o) => o.value === 'SignForce_Admin');
                const hasUser = this.permSetOptions.some((o) => o.value === 'SignForce_User');
                if (!hasAdmin) this.internalRole = 'standard';
                this.selectedPermSet = hasAdmin || hasUser
                    ? this.rolePermSetName(this.internalRole)
                    : this.permSetOptions[0].value;
                await this.loadAssigned();
            }
        }
        if (intR.status === 'fulfilled' && intR.value) {
            // Each provider card probes its own connection once it is handed `enabled`.
            const googleConfig = intR.value.find((c) => c.provider === 'GoogleDrive');
            if (googleConfig) {
                this.integrationGoogleDriveEnabled = googleConfig.enabled || false;
                this.integrationGoogleDriveTarget = googleConfig.target || '';
                this.integrationGoogleDriveTargetName = googleConfig.targetName || '';
                this.googleClientId = googleConfig.clientId || '';
                this.googleClientSecret = googleConfig.clientSecret || '';
            }
            const oneDriveConfig = intR.value.find((c) => c.provider === 'OneDrive');
            if (oneDriveConfig) {
                this.integrationOneDriveEnabled = oneDriveConfig.enabled || false;
                this.integrationOneDriveTarget = oneDriveConfig.target || '';
                this.integrationOneDriveTargetName = oneDriveConfig.targetName || '';
                this.oneDriveClientId = oneDriveConfig.clientId || '';
                this.oneDriveClientSecret = oneDriveConfig.clientSecret || '';
            }
        }
        if (!this.siteOptions.length) this.showScriptGen = true;

        // Land on the step the admin last had open (this browser). Fall back to the
        // Review step for an already-configured org, else Step 1 for a fresh setup.
        const savedStep = this.readSavedStep();
        if (savedStep) this.currentStep = savedStep;
        else if (alreadyConfigured) this.currentStep = STEP_LABELS.length;

        // Restore the locked (saved) state across reloads. Locked always shows the
        // Review step (read-only summary) with the Edit button.
        try { this.locked = window.localStorage.getItem(LOCK_STORAGE_KEY) === '1'; } catch (e) { /* storage blocked */ }
        if (this.locked) this.currentStep = TOTAL_STEPS;

        // Landing directly on a permission step must pin its perm-set group.
        if (this.currentStep === 3) this.applyPermStepMode(false);
        else if (this.currentStep === 4) this.applyPermStepMode(true);

        const failed = [cfgR, sitesR, owaR, statusR, usersR, guestR, intR].find((x) => x.status === 'rejected');
        if (failed) this.toast('Some data could not load', this.errMsg(failed.reason), 'warning');
        this.loading = false;
        // Only now allow auto-save — field setters above must not trigger writes.
        this._loaded = true;
    }
    async loadAssigned() {
        if (!this.selectedPermSet) {
            this.assignedUserIds = [];
            this.isDirty = false;
            return;
        }
        try {
            // The Standard tab hides users who already hold the Admin set (it is
            // a superset), so refresh who those are before loading assignments.
            if (this.isStandardRoleTab) {
                try {
                    this._adminAssignedIds = (await getAssignedUserIds({
                        permSetName: 'SignForce_Admin', userScope: 'internal'
                    })) || [];
                } catch (e) {
                    this._adminAssignedIds = [];
                }
            }
            const ids = this.isGuestMode
                ? await getAssignedGuestUserIds({ permSetName: this.selectedPermSet })
                : await getAssignedUserIds({ permSetName: this.selectedPermSet, userScope: this.userScope });
            let list = ids || [];
            if (this.isStandardRoleTab && this._adminAssignedIds.length) {
                const adminIds = new Set(this._adminAssignedIds);
                list = list.filter((id) => !adminIds.has(id));
            }
            this.assignedUserIds = list;
        } catch (e) {
            this.toast('Error', this.errMsg(e), 'error');
        } finally {
            this.isDirty = false;
        }
    }

    get isStandardRoleTab() {
        return !this.isGuestMode && this.currentStep === 3 && this.internalRole === 'standard';
    }

    // ---- Internal Users role tabs (Admin / Standard / Community) ----
    // Each tab pairs a permission set with the user population it manages:
    //   admin     → SignForce_Admin      → internal users (seat-checked)
    //   standard  → SignForce_User       → internal users (seat-checked)
    //   community → SignForce_User       → Experience Cloud users (no seat)
    @track internalRole = 'admin';
    @track _communityUsers = [];
    @track _adminAssignedIds = [];

    rolePermSetName(role) {
        return role === 'admin' ? 'SignForce_Admin' : 'SignForce_User';
    }

    get userScope() {
        return !this.isGuestMode && this.internalRole === 'community' ? 'community' : 'internal';
    }

    get roleTabs() {
        const has = (name) => (this.permSetOptions || []).some((o) => o.value === name);
        const tabs = [];
        if (has('SignForce_Admin')) tabs.push({ key: 'admin', label: 'Admin user' });
        if (has('SignForce_User')) {
            tabs.push({ key: 'standard', label: 'Standard user' });
            // Community tab hidden for now — re-enable when community signing
            // is rolled out. Backend getCommunityUsers/community scope stay.
            // tabs.push({ key: 'community', label: 'Community user' });
        }
        return tabs.map((t) => ({
            ...t,
            variant: t.key === this.internalRole ? 'brand' : 'neutral'
        }));
    }

    get hasRoleTabs() { return this.roleTabs.length > 0; }

    async handleRoleSelect(event) {
        const role = event.currentTarget.dataset.role;
        if (!role || role === this.internalRole) return;
        if (this.isDirty) {
            const proceed = await this.template.querySelector('c-signforce-confirm').open({
                title: 'Discard unsaved changes?',
                message: 'Your changes to "' + this.selectedPermSet
                    + '" haven\'t been applied yet. Switching tab drops them.',
                confirmLabel: 'Discard and switch',
                variant: 'danger'
            });
            if (!proceed) return;
        }
        this.internalRole = role;
        this.selectedPermSet = this.rolePermSetName(role);
        this.failures = [];
        if (role === 'community' && !this._communityUsers.length) {
            try {
                this._communityUsers = (await getCommunityUsers()) || [];
            } catch (e) {
                this._communityUsers = [];
            }
        }
        await this.loadAssigned();
    }

    // ---- wizard navigation ----
    get stepItems() {
        return STEP_LABELS.map((label, i) => {
            const num = i + 1;
            const isDone = num < this.currentStep;
            let cls = 'sf-step';
            if (num === this.currentStep) cls += ' sf-step_active';
            else if (isDone) cls += ' sf-step_done';
            return { num, label, cls, isDone };
        });
    }
    get progressLabel() {
        return `${this.currentStep} / ${this.totalSteps}`;
    }
    // Non-clickable step indicator while locked.
    get stepsClass() {
        return this.locked ? 'sf-steps sf-steps_locked' : 'sf-steps';
    }    get isStep1() { return this.currentStep === 1; } // Site
    get isStep2() { return this.currentStep === 2; } // Sender
    get isStep3() { return this.currentStep === 3; } // Internal Users
    get isStep4() { return this.currentStep === 4; } // Guest Users
    get isStep5() { return this.currentStep === 5; } // Integrations
    get isStep6() { return this.currentStep === 6; } // Review
    get isPermStep() { return this.currentStep === 3 || this.currentStep === 4; }
    get canGoBack() { return this.currentStep > 1; }
    get canGoNext() { return this.currentStep < this.totalSteps; }
    get isLastStep() { return this.currentStep === this.totalSteps; }

    handleNext() {
        if (this.currentStep >= this.totalSteps) return;
        const err = this.validateStep(this.currentStep);
        if (err) { this.stepError = err; return; }
        this.goToStep(this.currentStep + 1);
    }
    handleBack() {
        // Going back never validates — let admins move away from an incomplete step.
        if (this.currentStep > 1) this.goToStep(this.currentStep - 1);
    }

    // Jump straight to any step by clicking its indicator (tab-style nav).
    handleStepClick(event) {
        if (this.locked) return; // read-only after Save - click Edit to navigate
        const n = parseInt(event.currentTarget.dataset.step, 10);
        if (Number.isNaN(n) || n < 1 || n > this.totalSteps) return;
        // Moving forward must clear every step in between; moving back is free.
        if (n > this.currentStep) {
            for (let s = this.currentStep; s < n; s++) {
                const err = this.validateStep(s);
                // Navigate to the failing step FIRST, then set the error — goToStep
                // clears stepError, so setting it before would wipe the message.
                if (err) { this.goToStep(s); this.stepError = err; return; }
            }
        }
        this.goToStep(n);
    }

    goToStep(n) {
        // Persist any pending change before leaving the step, so a change made just
        // before Continue can't be lost in the debounce window.
        this.flushAutoSave();
        this.stepError = '';
        this.currentStep = n;
        try { window.localStorage.setItem(STEP_STORAGE_KEY, String(n)); } catch (e) { /* storage blocked */ }
        // Steps 3 (Internal Users) and 4 (Guest Users) are now separate steps —
        // each pins the permission-set picker to its own group.
        if (n === 3) this.applyPermStepMode(false);
        else if (n === 4) this.applyPermStepMode(true);
    }

    // Select the first perm set of the requested group (guest vs internal) for the
    // current permission step. Direct switch (no unsaved-changes prompt) — apply
    // changes on a step before moving on.
    applyPermStepMode(guest) {
        // Internal step lands on the active role tab's permission set, so the
        // tab highlight and the loaded user list always agree.
        const roleTarget = this.permSetOptions.some((o) => o.value === this.rolePermSetName(this.internalRole))
            ? this.rolePermSetName(this.internalRole)
            : this.firstInternalPermSet;
        const target = guest
            ? (this.guestPermSetNames && this.guestPermSetNames[0])
            : roleTarget;
        if (target && target !== this.selectedPermSet) {
            this.selectedPermSet = target;
            this.failures = [];
            this.isDirty = false;
            this.loadAssigned();
        }
    }

    readSavedStep() {
        try {
            const raw = window.localStorage.getItem(STEP_STORAGE_KEY);
            const n = parseInt(raw, 10);
            return !Number.isNaN(n) && n >= 1 && n <= this.totalSteps ? n : null;
        } catch (e) {
            return null;
        }
    }

    /**
     * Every input on a step must have a value before Continue. Returns an error
     * string to show inline, or '' when the step is complete. Steps with no direct
     * inputs (Permissions, Review) always pass.
     */
    validateStep(step) {
        if (step === 1 && !this.signingSiteBaseUrl.trim()) {
            return 'Signing Site Base URL is required. Select a detected site or enter the URL to continue.';
        }
        // Org-Wide Email (step 2) is optional — it only warns, never blocks (see
        // showOwaWarning). Auto-detect is used when none is chosen.

        // Step 3 (Internal Users): a REQUIRED internal permission set must have at
        // least one saved user. Agentforce is optional, so it doesn't count — check
        // the aggregate (saved) status across non-Agentforce internal perm sets, not
        // just the one currently selected in the dropdown.
        // Both permission steps gate on the SAVED aggregate (_permSetStatus), not
        // on the step being currently open — otherwise jumping straight from an
        // early step to a later one in the progress bar skips the gate entirely
        // (the old `this.currentStep === N` guard made validateStep(N) a no-op
        // unless you were already on step N).
        if (step === 3) {
            const required = (this._permSetStatus || []).filter(
                (p) => p.assignable && !this.isAgentforcePermSet(p.name)
            );
            if (required.length && !required.some((p) => (p.assigned || 0) > 0)) {
                return 'Assign at least one user to the eSignforce User permission set and click Apply changes before continuing. (Agentforce is optional.)';
            }
        }
        if (step === 4 && this.hasGuestPermSets) {
            const guest = (this._permSetStatus || []).filter(
                (p) => this.guestPermSetNames.indexOf(p.name) !== -1
            );
            if (guest.length && !guest.some((p) => (p.assigned || 0) > 0)) {
                return 'Assign your Experience site Guest User, then click Apply changes, before continuing.';
            }
            // The unsaved-selection warning only makes sense while step 4 is open.
            if (this.currentStep === 4 && this.isDirty) {
                return 'Click Apply changes to save your assignment before continuing.';
            }
        }

        if (step === 5) { // Integrations
            if (this.integrationGoogleDriveEnabled && !this.integrationGoogleDriveTarget) {
                return 'Google Drive is enabled but no destination folder is selected. Pick a folder or turn it off.';
            }
            if (this.integrationOneDriveEnabled && !this.integrationOneDriveTarget) {
                return 'OneDrive is enabled but no destination folder is selected. Pick a folder or turn it off.';
            }
        }
        return '';
    }
    handleStepKey(event) {
        if (event.key === 'Enter' || event.key === ' ' || event.key === 'Spacebar') {
            event.preventDefault();
            this.handleStepClick(event);
        }
    }

    // ---- site / config field handlers ----
    handleSiteSelect(event) {
        // Picking a detected site is a discrete choice — save now, no debounce.
        this.signingSiteBaseUrl = event.detail.value;
        if (this.stepError) this.stepError = '';
        this.autoSaveNow();
    }
    handleUrlChange(event) {
        // Typed URL — debounced so keystrokes coalesce into one save.
        this.signingSiteBaseUrl = event.detail.value;
        if (this.stepError) this.stepError = '';
        this.autoSave();
    }
    handlePortalAccountChange(event) {
        this.portalAccountId = event.detail.value;
        this.autoSaveNow();
    }
    handleOwaChange(event) {
        this.orgWideEmailId = event.detail.value;
    }

    handleSenderCardSelect(event) {
        const mode = event.currentTarget.dataset.mode;
        if (mode) this.senderEmailMode = mode;
    }

    /** Cards act as radios, so Enter and Space must select them. */
    handleSenderCardKey(event) {
        if (event.key !== 'Enter' && event.key !== ' ') return;
        event.preventDefault();
        const mode = event.currentTarget.dataset.mode;
        if (mode) this.senderEmailMode = mode;
    }

    /** The address picker lives inside a card; using it must not re-select. */
    stopCardClick(event) {
        event.stopPropagation();
        if (this.stepError) this.stepError = '';
        this.autoSaveNow();
    }
    handleTierChange(event) {
        this.defaultStorageTier = event.detail.value;
        this.autoSaveNow();
    }

    get hasSites() {
        return this.siteOptions && this.siteOptions.length > 0;
    }

    async handleRefreshSites() {
        try {
            const sites = await getSites();
            this.siteOptions = sites || [];
            this.toast(
                'Sites refreshed',
                this.hasSites ? `${this.siteOptions.length} site(s) found.` : 'No sites found yet.',
                this.hasSites ? 'success' : 'info'
            );
        } catch (e) {
            this.toast('Error', this.errMsg(e), 'error');
        }
    }

    // ---- site creation script generator ----
    toggleScriptGen() {
        this.showScriptGen = !this.showScriptGen;
    }
    showSetup() {
        this.showScriptGen = true;
    }
    openCliModal() {
        this.showCliModal = true;
    }
    closeCliModal() {
        this.showCliModal = false;
    }
    openManualModal() {
        this.showManualModal = true;
    }
    closeManualModal() {
        this.showManualModal = false;
    }

    // ---- verify the /signature page on the selected site ----
    get hasSelectedSite() {
        return !!(this.signingSiteBaseUrl && this.signingSiteBaseUrl.trim());
    }
    openSignaturePage() {
        const base = (this.signingSiteBaseUrl || '').trim().replace(/\/+$/, '');
        if (base) {
            window.open(base + '/signature', '_blank');
        }
    }
    handleScriptNameChange(event) {
        this.scriptSiteName = event.detail.value;
    }
    handleScriptPrefixChange(event) {
        this.scriptPrefix = event.detail.value;
    }
    handleScriptTemplateChange(event) {
        this.scriptTemplate = event.detail.value;
    }
    handleScriptAliasChange(event) {
        this.scriptOrgAlias = event.detail.value;
    }

    get generatedScript() {
        const name = (this.scriptSiteName || 'eSignforce Portal').replace(/"/g, '');
        const prefix = (this.scriptPrefix || 'sign').replace(/[^a-zA-Z0-9_-]/g, '');
        const template = this.scriptTemplate || 'Build Your Own (LWR)';
        const alias = this.scriptOrgAlias ? this.scriptOrgAlias.trim() : '<your-org-alias>';
        return (
            `sf community create --name "${name}" ` +
            `--template-name "${template}" ` +
            `--url-path-prefix "${prefix}" ` +
            `--target-org ${alias}`
        );
    }

    get sitePreviewUrl() {
        const prefix = (this.scriptPrefix || 'sign').replace(/[^a-zA-Z0-9_-]/g, '');
        return `https://<your-domain>.my.site.com/${prefix}`;
    }

    async copyScript() {
        try {
            await navigator.clipboard.writeText(this.generatedScript);
            this.toast('Copied', 'Creation command copied to clipboard.', 'success');
        } catch (e) {
            this.toast('Copy failed', 'Select the text and copy it manually.', 'warning');
        }
    }
    // Explicit "Save configuration" button: saves, shows a toast, and locks the
    // wizard (read-only) so the step tabs are disabled until Edit is clicked.
    async handleSave() {
        clearTimeout(this._autoSaveTimer);
        this.saving = true;
        try {
            const ok = await this.enqueueSave(true);
            if (ok) this.setLocked(true);
        } finally {
            this.saving = false;
        }
    }

    // Re-enable editing after a confirmation — unlock the step tabs and navigation.
    async handleEdit() {
        const proceed = await this.template.querySelector('c-signforce-confirm').open({
            title: 'Edit configuration?',
            message: 'This unlocks the setup steps so you can change your eSignforce configuration.',
            confirmLabel: 'Edit setup'
        });
        if (proceed) this.setLocked(false);
    }

    // Set + persist the locked state so it survives a page reload.
    setLocked(value) {
        this.locked = value;
        try { window.localStorage.setItem(LOCK_STORAGE_KEY, value ? '1' : '0'); } catch (e) { /* storage blocked */ }
    }

    // Silent auto-save after any field change. Debounced so rapid typing/toggling
    // coalesces into one write, and NO toast (only the explicit button toasts).
    autoSave() {
        if (!this._loaded) return; // don't save while the initial load is populating fields
        clearTimeout(this._autoSaveTimer);
        this._autoSaveTimer = setTimeout(() => {
            this._autoSaveTimer = null;
            this.enqueueSave(false);
        }, 450);
    }

    // Immediate save for discrete changes (dropdowns, toggles) — no debounce wait,
    // so rapid/back-to-back testing doesn't lose the change.
    autoSaveNow() {
        if (!this._loaded) return;
        clearTimeout(this._autoSaveTimer);
        this._autoSaveTimer = null;
        this.enqueueSave(false);
    }

    // Fire a pending debounced save immediately (on navigation / unmount) so a
    // just-made change is never left unsaved.
    flushAutoSave() {
        if (this._autoSaveTimer) {
            clearTimeout(this._autoSaveTimer);
            this._autoSaveTimer = null;
            if (this._loaded) this.enqueueSave(false);
        }
    }

    /**
     * Serialize every save (auto + button) through one chain so two writes never
     * overlap on the same org-default record (which would race → UNABLE_TO_LOCK_ROW).
     */
    enqueueSave(showToast) {
        this._savePromise = (this._savePromise || Promise.resolve())
            .catch(() => {}) // a prior failure must not block later saves
            .then(() => this.runSave(showToast));
        return this._savePromise;
    }

    async runSave(showToast) {
        try {
            // Sequential: both methods upsert the same record.
            await saveConfig({
                signingSiteBaseUrl: this.signingSiteBaseUrl,
                portalAccountId: this.portalAccountId,
                orgWideEmailId: this.orgWideEmailId,
                defaultStorageTier: this.defaultStorageTier,
                senderEmailMode: this.senderEmailMode
            });
            await saveIntegrationConfig({ jsonStr: JSON.stringify(this.integrationPayload()) });
            if (showToast) this.toast('Saved', 'eSignforce configuration saved.', 'success');
            return true;
        } catch (e) {
            if (showToast) {
                this.toast('Save failed', this.errMsg(e), 'error');
            } else {
                // Auto-save failures are silent to the user but logged for diagnosis.
                // eslint-disable-next-line no-console
                console.warn('[SignForce] auto-save failed:', this.errMsg(e));
            }
            return false;
        }
    }
    // ---- permission set (dual-listbox) handlers ----
    async handlePermSetChange(event) {
        const combobox = event.target;
        const newVal = event.detail.value;
        if (newVal === this.selectedPermSet) return;

        if (this.isDirty) {
            const proceed = await this.template.querySelector('c-signforce-confirm').open({
                title: 'Discard unsaved changes?',
                message: 'Your changes to "' + this.selectedPermSet
                    + '" haven\'t been applied yet. Switching permission set drops them.',
                confirmLabel: 'Discard and switch',
                variant: 'danger'
            });
            if (!proceed) {
                combobox.value = this.selectedPermSet;
                return;
            }
        }
        this.selectedPermSet = newVal;
        this.failures = [];
        await this.loadAssigned();
    }

    // Switch the selected permission set programmatically (used by the
    // "Manage Guest User access" / "Back to internal users" shortcut buttons),
    // honouring the same unsaved-changes guard as the dropdown.
    async selectPermSet(name) {
        if (!name || name === this.selectedPermSet) return;
        if (this.isDirty) {
            const proceed = await this.template.querySelector('c-signforce-confirm').open({
                title: 'Discard unsaved changes?',
                message: 'Your changes to "' + this.selectedPermSet
                    + '" haven\'t been applied yet. Switching permission set drops them.',
                confirmLabel: 'Discard and switch',
                variant: 'danger'
            });
            if (!proceed) return;
        }
        this.selectedPermSet = name;
        this.failures = [];
        await this.loadAssigned();
    }
    handleUsersChange(event) {
        this.assignedUserIds = event.detail.value;
        this.isDirty = true;
        if (this.stepError) this.stepError = '';
    }
    handleSelectAll() {
        this.assignedUserIds = this.userOptions.map((o) => o.value);
        this.isDirty = true;
        if (this.stepError) this.stepError = '';
    }
    handleClearAll() {
        this.assignedUserIds = [];
        this.isDirty = true;
        if (this.stepError) this.stepError = '';
    }

    async handleApplyAssignments() {
        if (!this.selectedPermSet) return;
        this.applying = true;
        try {
            const res = this.isGuestMode
                ? await applyGuestAssignments({
                    permSetName: this.selectedPermSet,
                    selectedUserIds: this.assignedUserIds
                })
                : await applyAssignments({
                    permSetName: this.selectedPermSet,
                    selectedUserIds: this.assignedUserIds,
                    userScope: this.userScope
                });
            this.failures = res.failures || [];
            this.toast('Permission set updated', res.message, res.failed > 0 ? 'warning' : 'success');
            await this.loadAssigned();
            await this.refreshPermSetStatus();
            // Applying (saving) an assignment clears a "please assign / apply" block.
            if (this.stepError) this.stepError = '';
        } catch (e) {
            this.toast('Update failed', this.errMsg(e), 'error');
        } finally {
            this.applying = false;
        }
    }

    // Re-pull assignment counts so the Review step reflects the latest apply.
    async refreshPermSetStatus() {
        try {
            this._permSetStatus = (await getPermissionSetStatus()) || [];
        } catch (e) {
            /* leave the previous snapshot; review just shows slightly stale counts */
        }
    }

    get userOptions() {
        if (this.isGuestMode) return this._guestUsers;
        if (this.internalRole === 'community') return this._communityUsers;
        // Both Admin and Standard tabs show ALL active internal users (licence
        // shown in each row's label). No tab-specific filtering — an admin can
        // be given either role; the seat/permset logic on Apply still applies.
        return this._internalUsers;
    }
    get isGuestMode() {
        return this.guestPermSetNames
            && this.guestPermSetNames.indexOf(this.selectedPermSet) !== -1;
    }
    get hasPermSets() {
        return this.permSetOptions && this.permSetOptions.length > 0;
    }
    get hasUsers() {
        return this.userOptions && this.userOptions.length > 0;
    }
    get hasGuestPermSets() {
        return this.guestPermSets && this.guestPermSets.length > 0;
    }
    // Permission sets shown in the dropdown for the active tab: internal perm
    // sets on the Internal tab, guest perm set(s) on the Guest tab.
    get visiblePermSetOptions() {
        const opts = this.permSetOptions || [];
        return this.isGuestMode
            ? opts.filter((o) => this.guestPermSetNames.indexOf(o.value) !== -1)
            : opts.filter((o) => this.guestPermSetNames.indexOf(o.value) === -1);
    }
    get hasVisiblePermSets() {
        return this.visiblePermSetOptions.length > 0;
    }
    get noPermSetText() {
        return this.isGuestMode
            ? 'No Experience-site guest permission set found. Create your Experience site in Step 1 first, then return here.'
            : 'No assignable internal eSignforce permission sets found.';
    }
    // First non-guest (internal) perm set value — target of "Back to internal".
    get firstInternalPermSet() {
        const opt = (this.permSetOptions || []).find(
            (o) => this.guestPermSetNames.indexOf(o.value) === -1
        );
        return opt ? opt.value : '';
    }
    // Mode-aware empty-state copy for the user list.
    get noUsersText() {
        if (this.isGuestMode) {
            return 'No Experience site Guest Users found. Create your Experience site in Step 1 first, then return here.';
        }
        return this.internalRole === 'community'
            ? 'No active community (Experience Cloud) users found to assign.'
            : 'No active internal users found to assign.';
    }
    get hasFailures() {
        return this.failures && this.failures.length > 0;
    }
    get isLargeUserList() {
        return this.userOptions && this.userOptions.length >= LARGE_USER_THRESHOLD;
    }
    get assignedSummary() {
        const kind = this.isGuestMode ? 'guest' : 'internal';
        return `${this.assignedUserIds.length} of ${this.userOptions.length} ${kind} users assigned`;
    }

    // ---- review-step display helpers ----
    // Non-blocking heads-up on Step 2: OWA is optional, but flag that no verified
    // sender is set so the admin knows auto-detect will be used.
    get sendsAsCurrentUser() {
        return this.senderEmailMode === 'CurrentUser';
    }

    get sendsAsOrgWide() {
        return !this.sendsAsCurrentUser;
    }

    // aria-checked needs a string, and a getter cannot take an argument.
    get sendsAsCurrentUserStr() { return String(this.sendsAsCurrentUser); }
    get sendsAsOrgWideStr()     { return String(this.sendsAsOrgWide); }

    get orgWideCardClass() {
        return this.sendsAsOrgWide ? 'sf-sender-card sf-sender-card-on' : 'sf-sender-card';
    }

    get currentUserCardClass() {
        return this.sendsAsCurrentUser ? 'sf-sender-card sf-sender-card-on' : 'sf-sender-card';
    }

    /** The admin's own address, as a stand-in for whoever sends an agreement. */
    get currentUserFrom() {
        const name = this._userName;
        const email = this._userEmail;
        if (!email) return 'the sending user';
        return name ? `${name} <${email}>` : email;
    }

    get showOwaWarning() {
        // The org-wide address still matters in "send as the user" mode — guest
        // signing has no user to send as, so completion emails fall back to it.
        return !this.orgWideEmailId;
    }

    get reviewSiteUrl() { return this.signingSiteBaseUrl || '- not set -'; }

    /* The address recipients will actually see, resolved from Step 2's choice.
       Review lists outcomes, not settings — naming the mode and the org-wide
       address separately left the admin to work out which one wins. */
    get reviewSenderAddress() {
        return this.sendsAsCurrentUser ? this.currentUserFrom : this.reviewOwa;
    }

    // Show the readable address, not the OrgWideEmailAddress id we persist.
    get reviewOwa() {
        if (!this.orgWideEmailId) return 'Auto-detect';
        const hit = (this.owaOptions || []).find((o) => o.value === this.orgWideEmailId);
        return hit ? hit.label : this.orgWideEmailId;
    }
    get reviewPortal() { return this.portalAccountId || '- not set -'; }
    get reviewTier() { return this.defaultStorageTier || 'Package default'; }

    /**
     * Per-permission-set assignment summary for Review. Internal sets show a live
     * assigned/total count; guest sets are assigned on the site's Guest Profile, not
     * here, so they show a neutral note instead of a pass/fail.
     */
    get reviewPermSets() {
        return (this._permSetStatus || []).map((p) => {
            const count = p.assigned || 0;
            const done = count > 0;
            // Assigned user names (server caps at 50); show "+N more" beyond that.
            const names = p.assignedNames || [];
            let users = names.join(', ');
            if (count > names.length) {
                users = users ? `${users} +${count - names.length} more` : `${count} users`;
            }
            let statusText;
            if (!p.assignable) {
                // Guest perm set: show its Guest-User assignment.
                statusText = done
                    ? `Assigned to ${count} guest user${count === 1 ? '' : 's'}`
                    : 'No guest user assigned';
            } else {
                statusText = done
                    ? `Assigned to ${count} of ${p.totalInternal} user${count === 1 ? '' : 's'}`
                    : 'Not assigned to any user';
            }
            return {
                key: p.name,
                label: p.label,
                statusText,
                pillClass: done ? 'sf-perm-pill sf-perm-pill_on' : 'sf-perm-pill sf-perm-pill_off',
                users
            };
        });
    }
    get hasReviewPermSets() {
        return this.reviewPermSets.length > 0;
    }

    // Warn on the Permissions step when no internal user holds a SignForce permission
    // set — nobody can use the app until at least one is assigned. Guest sets are
    // assigned on the site Guest Profile, so they don't count here.
    // Internal-tab warning: the SELECTED permission set has no users. Live and
    // per-set — tracks the "0 of N assigned" badge and updates as the admin picks a
    // set or stages users, instead of an aggregate snapshot that could go stale.
    // The Agentforce permission set is optional — excluded from the "internal users
    // required" gate. Matches the bare or namespaced 'Agentforce_SignForce_User'.
    isAgentforcePermSet(name) {
        return !!name && name.indexOf('Agentforce') !== -1;
    }

    get showNoAssignmentWarning() {
        // Only meaningful when there IS a permission set to assign to — otherwise the
        // "no assignable permission sets found" message covers it.
        return this.hasPermSets && !this.isGuestMode
            && (!this.assignedUserIds || this.assignedUserIds.length === 0);
    }

    // Guest-tab warning: no Guest User assigned means external signers can't open
    // signing links. Same live, per-set basis as the internal warning.
    get showNoGuestAssignmentWarning() {
        return this.isGuestMode && (!this.assignedUserIds || this.assignedUserIds.length === 0);
    }
    get reviewGoogleDrive() {
        if (!this.integrationGoogleDriveEnabled) return 'Disabled';
        // Show the folder name, not its id; fall back to the id only if unresolved.
        const folder = this.integrationGoogleDriveTargetName || this.integrationGoogleDriveTarget || 'Not Specified';
        return `Enabled (Folder: ${folder})`;
    }
    get reviewOneDrive() {
        if (!this.integrationOneDriveEnabled) return 'Disabled';
        const folder = this.integrationOneDriveTargetName || this.integrationOneDriveTarget || 'Not Specified';
        return `Enabled (Folder: ${folder})`;
    }

    /**
     * True when neither provider is set up to receive documents, so Step 4 warns that
     * completed agreements stay in Salesforce Files. A provider counts as connected
     * once it is enabled with a destination folder (matching primaryProvider() on the
     * server), OR once its card reports a live connection.
     */
    get noCloudConnected() {
        // "Will completed agreements push to cloud?" — a provider counts only when it
        // is enabled AND has a target folder (matches primaryProvider() on the server
        // and the Review step). The live OAuth `connected` flag is deliberately NOT
        // used: it stays true after the toggle is switched off, which would wrongly
        // hide the "using Salesforce storage" banner even though nothing will push.
        const google = this.integrationGoogleDriveEnabled && this.integrationGoogleDriveTarget;
        const oneDrive = this.integrationOneDriveEnabled && this.integrationOneDriveTarget;
        return !google && !oneDrive;
    }

    // ---- integration event handlers ----

    /** Payload for saveIntegrationConfig — every provider the wizard manages. */
    integrationPayload() {
        return [
            {
                provider: 'GoogleDrive',
                enabled: this.integrationGoogleDriveEnabled,
                target: this.integrationGoogleDriveTarget,
                targetName: this.integrationGoogleDriveTargetName,
                clientId: this.googleClientId,
                clientSecret: this.googleClientSecret
            },
            {
                provider: 'OneDrive',
                enabled: this.integrationOneDriveEnabled,
                target: this.integrationOneDriveTarget,
                targetName: this.integrationOneDriveTargetName,
                clientId: this.oneDriveClientId,
                clientSecret: this.oneDriveClientSecret
            }
        ];
    }

    /**
     * A provider card toggled itself on/off, connected, or picked a folder.
     * Only ONE cloud provider may be active at a time: turning one on while the
     * other is already on asks for confirmation, then switches the other off.
     */
    async handleIntegrationConfigChange(event) {
        const { provider, enabled, target, targetLabel } = event.detail;
        const isGoogle = provider === 'GoogleDrive';

        // Snapshot BEFORE applying — used to detect the off→on transition.
        const wasEnabled = isGoogle ? this.integrationGoogleDriveEnabled : this.integrationOneDriveEnabled;
        const otherEnabled = isGoogle ? this.integrationOneDriveEnabled : this.integrationGoogleDriveEnabled;

        // Apply this provider's reported state immediately, so the card's async
        // connection-probe re-notification doesn't re-trigger the switch prompt.
        this.applyProviderState(provider, enabled, target, targetLabel);

        // Single-active-provider gate: only on a genuine off→on toggle, and only
        // when the OTHER provider is currently on.
        if (enabled && !wasEnabled && otherEnabled) {
            const thisLabel = isGoogle ? 'Google Drive' : 'OneDrive';
            const otherLabel = isGoogle ? 'OneDrive' : 'Google Drive';
            const confirmed = await this.template.querySelector('c-signforce-confirm').open({
                title: 'Switch cloud provider?',
                message: `${otherLabel} is connected now. Only one provider can be active, so turning on ${thisLabel} switches ${otherLabel} off.`,
                confirmLabel: `Switch to ${thisLabel}`
            });
            if (confirmed) {
                // Switch the other provider off.
                this.applyProviderState(isGoogle ? 'OneDrive' : 'GoogleDrive', false, '', '');
            } else {
                // Keep the existing provider; undo this toggle.
                this.applyProviderState(provider, false, '', targetLabel);
            }
        }

        if (this.stepError && this.currentStep === 5) {
            this.stepError = this.validateStep(5);
        }
        // Toggle/folder are discrete choices — persist immediately.
        this.autoSaveNow();
    }

    applyProviderState(provider, enabled, target, targetLabel) {
        if (provider === 'GoogleDrive') {
            this.integrationGoogleDriveEnabled = enabled;
            this.integrationGoogleDriveTarget = target;
            this.integrationGoogleDriveTargetName = targetLabel || '';
        } else if (provider === 'OneDrive') {
            this.integrationOneDriveEnabled = enabled;
            this.integrationOneDriveTarget = target;
            this.integrationOneDriveTargetName = targetLabel || '';
        }
    }

    // ---- utils ----
    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
    errMsg(e) {
        return (e && e.body && e.body.message) || (e && e.message) || 'Unexpected error';
    }
}