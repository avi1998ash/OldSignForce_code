import { LightningElement, api, track } from 'lwc';
import testIntegration from '@salesforce/apex/SignForceAdminConfigController.testIntegration';
import getIntegrationConnectUrl from '@salesforce/apex/SignForceAdminConfigController.getIntegrationConnectUrl';
import listGoogleFolders from '@salesforce/apex/SignForceAdminConfigController.listGoogleFolders';
import createGoogleFolder from '@salesforce/apex/SignForceAdminConfigController.createGoogleFolder';
import listOneDriveFolders from '@salesforce/apex/SignForceAdminConfigController.listOneDriveFolders';
import createOneDriveFolder from '@salesforce/apex/SignForceAdminConfigController.createOneDriveFolder';
import disconnectIntegration from '@salesforce/apex/SignForceAdminConfigController.disconnectIntegration';
import getGooglePickerConfig from '@salesforce/apex/SignForceAdminConfigController.getGooglePickerConfig';
import getGoogleApiKey from '@salesforce/apex/SignForceAdminConfigController.getGoogleApiKey';
import saveGoogleApiKey from '@salesforce/apex/SignForceAdminConfigController.saveGoogleApiKey';
import getPickerTrustedSites from '@salesforce/apex/SignForceAdminConfigController.getPickerTrustedSites';

// Each provider keeps its own Apex entry points and its own backend action names.
// Google's have been in production since before OneDrive existed — they are not
// routed through a shared generic method.
const FOLDER_APIS = {
    GoogleDrive: { list: listGoogleFolders, create: createGoogleFolder },
    OneDrive: { list: listOneDriveFolders, create: createOneDriveFolder }
};

/**
 * One cloud storage provider (Google Drive, OneDrive, …) as a self-contained card:
 * enable toggle, OAuth connect, destination folder picker, test and disconnect.
 *
 * Owns its own connection state; reports enabled/target back to the parent via a
 * `configchange` event so the parent can persist all providers in one save.
 */
export default class CloudIntegrationCard extends LightningElement {
    /** Backend provider key, e.g. 'GoogleDrive' or 'OneDrive'. */
    @api provider;
    /** Display name, e.g. 'Google Drive'. */
    @api label;
    /** Static resource URL for the provider logo. */
    @api logoUrl;
    /** Sentence describing what enabling this provider does. */
    @api helpText;

    @api
    get enabled() {
        return this._enabled;
    }
    set enabled(value) {
        this._enabled = value === true;
    }

    @api
    get target() {
        return this._target;
    }
    set target(value) {
        this._target = value || '';
    }

    // Saved folder NAME, persisted alongside the id — without it a reload could
    // only show the raw id for any folder the list endpoint no longer returns.
    @api
    get targetName() {
        return this._targetName;
    }
    set targetName(value) {
        if (!this._targetName) this._targetName = value || '';
    }

    @track _enabled = false;
    @track _target = '';
    @track connected = false;
    @track message = '';
    @track messageType = 'info';   // 'success' | 'error' | 'warning' | 'info'
    @track folders = [];
    @track showCreateFolderModal = false;
    @track newFolderName = '';
    @track busy = false;
    // Google Picker API key (Google Drive only). Draft is kept separate so an
    // abandoned edit never overwrites what is saved.
    @track apiKey = '';
    @track apiKeyDraft = '';
    @track apiKeyOpen = false;
    // Domains the Picker needs that this org has not trusted yet.
    @track missingSites = [];
    // True while probing the connection + loading folders — the body shows a spinner
    // instead of a half-loaded state.
    @track loading = false;

    // Google Picker state. Only used when usePicker is true.
    @track showPicker = false;
    @track pickerUrl = '';
    _targetName = '';
    _pickerCfg = null;
    _onMessage = null;

    _checked = false;

    /**
     * Google goes through the Picker; every other provider keeps its dropdown.
     *
     * Google's OAuth scope is drive.file, which can only see what this app made
     * and what the admin explicitly picked — so there is nothing to list, and the
     * Picker is how the admin grants access to one folder. OneDrive still asks
     * for Files.ReadWrite and can list, so it is left alone.
     */
    get usePicker() {
        return this.provider === 'GoogleDrive';
    }

    disconnectedCallback() {
        this._detachPickerListener();
    }

    renderedCallback() {
        // The parent sets `enabled` after its own Apex load resolves, which can land
        // after connectedCallback. Probe once, the first time we are enabled.
        if (this._enabled && !this._checked) {
            this._checked = true;
            this.refreshConnection();
            // usePicker is only meaningful once the provider is known, which is
            // also only true from here - so the key loads on the same pass.
            this.loadApiKey();
            this.checkTrustedSites();
        }
    }

    // ---- derived state ----

    get statusClass() {
        return this.connected ? 'sf-status sf-status_on' : 'sf-status sf-status_off';
    }
    get statusLabel() {
        return this.connected ? 'Connected' : 'Not connected';
    }
    get cardClass() {
        // Highlight the whole card once the provider is switched on.
        return this._enabled ? 'sf-int-card sf-int-card_on' : 'sf-int-card sf-int-card_off';
    }
    get logoClass() {
        // Full-colour logo when enabled, greyed when off — visible in both states.
        return this._enabled ? 'sf-int-logo' : 'sf-int-logo sf-int-logo_muted';
    }
    get connectLabel() {
        return `Connect ${this.label}`;
    }
    get subtitle() {
        if (!this.connected) return `Sign in to choose a destination folder.`;
        const match = (this.message || '').match(/Connected as\s+(.+?)\s*\(([^)]+)\)/);
        return match ? `${match[1]} · ${match[2]}` : 'Connected account';
    }
    // Header subtitle: what the integration does when off, a loading note while
    // probing, the connection state once resolved.
    get headerSubtitle() {
        if (!this._enabled) return this.helpText;
        if (this.loading) return 'Checking connection…';
        return this.subtitle;
    }
    get folderOptions() {
        const opts = this.folders.map((f) => ({ label: f.name, value: f.id }));
        // A previously saved target may not be in the list (e.g. it is a nested
        // folder, which the backend no longer returns). Keep it selectable.
        if (this._target && !opts.some((o) => o.value === this._target)) {
            opts.unshift({
                label: this._targetName
                    ? `${this._targetName} (currently selected)`
                    : `Currently selected folder (${this._target})`,
                value: this._target
            });
        }
        return opts;
    }
    /** Set the alert copy and its severity together. */
    setMessage(text, type) {
        this.message = text;
        this.messageType = type || 'info';
    }

    get hasAlert() {
        const m = (this.message || '').trim();
        return !!m && !m.startsWith('Connected as');
    }
    get alertText() {
        return this.message || '';
    }
    get alertClass() {
        // Severity is carried by messageType, not by sniffing the copy. The old
        // version prefixed the string with an emoji, stripped it back out to
        // display, and re-read it to pick the colour — so any wording change
        // silently reclassified the alert.
        return 'sf-alert sf-alert_' + (this.messageType || 'info');
    }
    get createFolderDisabled() {
        return !this.newFolderName || !this.newFolderName.trim();
    }

    /** Human-readable name of the selected folder, for the parent's review step. */
    get targetLabel() {
        if (!this._target) return '';
        // The Picker hands back the name with the id, so prefer that. It only
        // lives for this session: after a reload we can no longer look a folder
        // name up, because drive.file cannot read a folder it was not given.
        if (this._targetName) return this._targetName;
        const hit = this.folders.find((f) => f.id === this._target);
        return hit ? hit.name : this._target;
    }

    // ---- events out ----

    // The parent persists only the folder id, but needs the name (targetLabel) to
    // show in Review and the live connected flag to decide the "no cloud" banner.
    notifyChange() {
        this.dispatchEvent(
            new CustomEvent('configchange', {
                detail: {
                    provider: this.provider,
                    enabled: this._enabled,
                    target: this._target,
                    targetLabel: this.targetLabel,
                    connected: this.connected
                }
            })
        );
    }

    // ---- handlers ----

    handleEnabledChange(event) {
        this._enabled = event.target.checked;
        this.notifyChange();
        if (this._enabled) this.refreshConnection();
    }

    handleFolderSelect(event) {
        this._target = event.detail.value;
        // Remember the picked folder's NAME so the saved selection can be shown
        // by name after a reload, not by raw id.
        const hit = (this.folders || []).find((f) => f.id === this._target);
        if (hit) this._targetName = hit.name;
        this.notifyChange();
    }

    async refreshConnection() {
        this.loading = true;
        try {
            const res = await testIntegration({ provider: this.provider });
            this.connected = res.success || false;
            this.setMessage(res.success ? res.message : 'Not connected: ' + res.message,
                res.success ? 'success' : 'error');
            if (this.connected) await this.fetchFolders();
        } catch (e) {
            this.connected = false;
            this.setMessage('Not connected: ' + this.errMsg(e), 'error');
        } finally {
            this.loading = false;
        }
        // Report the resolved connected flag (and, once folders are in, the folder
        // name) back up so the parent's banner and review reflect reality.
        this.notifyChange();
    }

    get folderApi() {
        return FOLDER_APIS[this.provider];
    }

    async fetchFolders() {
        // Under drive.file this call fails by design — there is no list to fetch.
        // Returning early keeps a red "Could not load folders" alert off a card
        // that is working perfectly well.
        if (this.usePicker) return;
        const api = this.folderApi;
        if (!api) return;
        try {
            const res = await api.list();
            if (res.success) {
                this.folders = res.folders || [];
            } else {
                this.setMessage(this.friendlyError(res.message), 'error');
            }
        } catch (e) {
            this.setMessage(this.friendlyError(this.errMsg(e)), 'error');
        }
    }

    handleRefreshFolders() {
        this.fetchFolders();
    }

    async handleConnect() {
        this.busy = true;
        this.setMessage('Generating sign-in URL…', 'info');
        try {
            const res = await getIntegrationConnectUrl({ provider: this.provider });
            if (!res.success || !res.url) {
                this.setMessage('Error connecting: ' + (res.message || 'no URL returned'), 'error');
                return;
            }
            this.setMessage('Opening authentication popup…', 'info');
            const popup = window.open(res.url, '_blank', 'width=600,height=700');
            // The provider redirects to the backend, which closes the tab on success.
            // Polling for closure is the only signal available cross-origin.
            const timer = setInterval(async () => {
                if (popup && !popup.closed) return;
                clearInterval(timer);
                this.setMessage('Verifying connection status…', 'info');
                await this.refreshConnection();
                if (!this.connected) {
                    this.setMessage('Connection failed, or the window was closed.', 'error');
                } else if (this.messageType === 'error') {
                    // refreshConnection loads the folder list, and that can fail on an
                    // account that signed in perfectly well - no OneDrive provisioned,
                    // for instance. Keep that message and its severity. Prefixing it
                    // with "Connected." and stamping the whole thing green (what this
                    // did before) painted a red problem as a success and buried the
                    // one sentence the admin needed to read.
                    this.setMessage('Connected, but ' + this.lowerFirst(this.message), 'warning');
                } else {
                    this.setMessage('Connected.', 'success');
                }
            }, 1000);
        } catch (e) {
            this.setMessage('Error connecting: ' + this.errMsg(e), 'error');
        } finally {
            this.busy = false;
        }
    }

    async handleTest() {
        this.setMessage('Testing connection…', 'info');
        try {
            const res = await testIntegration({ provider: this.provider });
            this.connected = res.success || false;
            this.setMessage(
                res.success
                    ? 'Connection successful. ' + res.message
                    : 'Connection failed: ' + res.message,
                res.success ? 'success' : 'error'
            );
            if (this.connected) await this.fetchFolders();
        } catch (e) {
            this.connected = false;
            this.setMessage('Error testing connection: ' + this.errMsg(e), 'error');
        }
        // Report the (possibly changed) connected flag + resolved folder name up.
        this.notifyChange();
    }

    async handleDisconnect() {
        this.setMessage('Disconnecting…', 'info');
        try {
            const res = await disconnectIntegration({ provider: this.provider });
            if (res.success) {
                this.connected = false;
                this.folders = [];
                this._target = '';
                this.setMessage('Disconnected.', 'success');
                this.notifyChange();
            } else {
                this.setMessage('Disconnect failed: ' + res.message, 'error');
            }
        } catch (e) {
            this.setMessage('Error disconnecting: ' + this.errMsg(e), 'error');
        }
    }

    // ---- Google Picker ----

    /**
     * Opens the Picker.
     *
     * The token is fetched first and held, then pushed into the frame over
     * postMessage once it says it is ready. It deliberately never goes on the
     * iframe URL: query strings survive in browser history, Referer headers and
     * server logs, and this one carries a live Drive token.
     */
    async handleOpenPicker() {
        this.busy = true;
        this.setMessage('Preparing Google Drive…', 'info');
        try {
            const cfg = await getGooglePickerConfig();
            if (!cfg.success) {
                this.setMessage(cfg.message || 'Could not open the folder picker.', 'error');
                return;
            }
            this._pickerCfg = cfg;
            this._attachPickerListener();
            this.pickerUrl = cfg.pageUrl;
            this.showPicker = true;
            this.setMessage('', 'info');
        } catch (e) {
            this.setMessage('Could not open the folder picker: ' + this.errMsg(e), 'error');
        } finally {
            this.busy = false;
        }
    }

    handleClosePicker() {
        this.showPicker = false;
        this.pickerUrl = '';
        this._pickerCfg = null;
        this._detachPickerListener();
    }

    _attachPickerListener() {
        this._detachPickerListener();
        this._onMessage = (event) => {
            // Only the Visualforce frame we opened may talk to us. Everything on
            // the page can post messages, so an unchecked handler is an open door.
            if (!this._isTrustedPickerOrigin(event.origin)) return;
            const data = event.data;
            if (!data || typeof data.type !== 'string') return;

            if (data.type === 'sf-picker-ready') {
                const frame = this.template.querySelector('iframe.sf-picker-frame');
                if (frame && frame.contentWindow && this._pickerCfg) {
                    frame.contentWindow.postMessage({
                        type: 'sf-picker-open',
                        accessToken: this._pickerCfg.accessToken,
                        developerKey: this._pickerCfg.developerKey
                    }, event.origin);
                }
            } else if (data.type === 'sf-picker') {
                // The id and name cross a postMessage boundary, so treat them as
                // input, not data: a Drive file id is strictly [-_A-Za-z0-9], and
                // the name is display-only text — anything markup-ish is dropped
                // before it can reach a template binding or a saved target.
                const safeId = String(data.id || '').replace(/[^-_A-Za-z0-9]/g, '');
                const safeName = String(data.name || '')
                    .replace(/[<>"'&`]/g, '')
                    .slice(0, 120);
                if (!safeId) { this.handleClosePicker(); return; }
                this._target = safeId;
                this._targetName = safeName;
                this.handleClosePicker();
                this.notifyChange();
                this.setMessage(`Folder "${safeName}" selected.`, 'success');
            } else if (data.type === 'sf-picker-cancel') {
                this.handleClosePicker();
            } else if (data.type === 'sf-picker-error') {
                this.handleClosePicker();
                this.setMessage(data.message || 'The folder picker could not open.', 'error');
            }
        };
        window.addEventListener('message', this._onMessage);
    }

    _detachPickerListener() {
        if (this._onMessage) {
            window.removeEventListener('message', this._onMessage);
            this._onMessage = null;
        }
    }

    /**
     * The Visualforce frame runs on the org's own Visualforce domain, which is a
     * different host from the Lightning domain and differs per org and per
     * namespace — so match on shape rather than on a fixed string.
     */
    _isTrustedPickerOrigin(origin) {
        if (!origin || typeof origin !== 'string') return false;
        if (!origin.startsWith('https://')) return false;
        return /\.(visual\.force\.com|vf\.force\.com|salesforce-sites\.com|force\.com)$/.test(origin);
    }

    // ---- create folder modal ----

    openCreateFolderModal() {
        this.newFolderName = '';
        this.showCreateFolderModal = true;
    }
    closeCreateFolderModal() {
        this.showCreateFolderModal = false;
    }
    handleNewFolderNameChange(event) {
        this.newFolderName = event.detail.value;
    }
    async handleCreateFolderSubmit() {
        const name = (this.newFolderName || '').trim();
        if (!name) return;
        const api = this.folderApi;
        if (!api) return;
        this.busy = true;
        try {
            const res = await api.create({ folderName: name, parentId: null });
            if (res.success) {
                this.showCreateFolderModal = false;
                this._target = res.folderId;
                // Refresh the folder list FIRST so targetLabel can resolve the new
                // folder's name, then notify — otherwise the parent gets the raw id.
                await this.fetchFolders();
                this.notifyChange();
                this.setMessage(`Folder “${res.folderName}” created and selected.`, 'success');
            } else {
                this.setMessage('Could not create folder: ' + res.message, 'error');
            }
        } catch (e) {
            this.setMessage('Could not create folder: ' + this.errMsg(e), 'error');
        } finally {
            this.busy = false;
        }
    }

    errMsg(e) {
        return e?.body?.message || e?.message || String(e);
    }

    /** "This account has no…" -> "this account has no…", for mid-sentence use. */
    lowerFirst(text) {
        const s = String(text || '');
        return s ? s.charAt(0).toLowerCase() + s.slice(1) : s;
    }

    /**
     * Turns a provider/Graph error into something an admin can act on.
     *
     * The backend passes the provider's raw response straight through, which for
     * Microsoft Graph is a nested JSON blob - status, error code, localised text,
     * request ids. Rendering that verbatim tells the admin nothing about what to
     * DO, and it leaks internal request ids into the UI. Each case below maps a
     * known failure to the actual next step; anything unrecognised falls back to
     * a plain sentence rather than the blob.
     */
    friendlyError(raw) {
        const text = String(raw || '');
        const label = this.label || 'the provider';

        // No drive provisioned. Graph answers /me/drive with itemNotFound when the
        // signed-in account has never had OneDrive set up (personal accounts that
        // skipped it, or work accounts with no OneDrive licence). The account is
        // genuinely connected, so "reconnect" would be the wrong advice.
        if (/itemNotFound|Item does not exist/i.test(text)) {
            return this.provider === 'OneDrive'
                ? 'This Microsoft account does not have a OneDrive. Open onedrive.com once with this account to set it up, or reconnect using an account that already has OneDrive.'
                : 'The folder could not be found. It may have been deleted or moved.';
        }

        if (/InvalidAuthenticationToken|unauthenticated|401|expired/i.test(text)) {
            return 'The connection to ' + label + ' has expired. Disconnect and connect again.';
        }
        if (/accessDenied|forbidden|403/i.test(text)) {
            return 'This account is not allowed to list folders. Check the permissions granted during sign-in.';
        }
        if (/activityLimitReached|throttl|429/i.test(text)) {
            return label + ' is rate limiting us. Wait a minute and press refresh.';
        }
        if (/quotaLimitReached|insufficient.*storage/i.test(text)) {
            return 'This account is out of storage.';
        }
        if (/Not connected/i.test(text)) {
            return 'Not connected to ' + label + ' yet. Use Connect above.';
        }

        // Unrecognised. Keep the first sentence if it reads like prose; never
        // return JSON, a stack trace, or an HTTP status line.
        const firstSentence = text.split(/[.\n{]/)[0].trim();
        const looksLikeProse = firstSentence
            && firstSentence.length < 120
            && !/^HTTP\s|^\{|^\[/.test(firstSentence);
        return looksLikeProse
            ? firstSentence + '.'
            : 'Could not reach ' + label + '. Try refresh, or disconnect and connect again.';
    }

    /* ── Google API key ──────────────────────────────────────────────────
       The Picker needs a Google API key that is not shipped with the package,
       so every org must supply its own. Kept beside the folder chooser because
       that is the only place the missing key ever shows up. */

    async loadApiKey() {
        if (!this.usePicker) return;
        try {
            const k = await getGoogleApiKey();
            this.apiKey = k || '';
            this.apiKeyDraft = this.apiKey;
        } catch (e) {
            // Non-fatal: the field simply starts empty.
            this.apiKey = '';
        }
    }

    get hasApiKey() { return !!(this.apiKey && this.apiKey.trim()); }
    // Collapsed by default now that the key is optional - an empty field is a
    // valid, working state, so it should not look like something to fill in.
    get showApiKeyField() { return this.usePicker && this.apiKeyOpen; }
    get apiKeyToggleText() { return this.hasApiKey ? 'Change' : 'Add a key'; }
    get apiKeyToggleLabel() { return this.apiKeyOpen ? 'Hide' : this.apiKeyToggleText; }
    get apiKeyDirty() { return (this.apiKeyDraft || '') !== (this.apiKey || ''); }
    get apiKeySaveDisabled() { return this.busy || !this.apiKeyDirty; }

    get apiKeyMasked() {
        if (!this.hasApiKey) return '';
        const k = this.apiKey.trim();
        return k.length <= 8 ? '••••' : `${k.slice(0, 4)}••••••${k.slice(-4)}`;
    }

    handleApiKeyInput(e) { this.apiKeyDraft = e.target.value; }
    handleApiKeyToggle() { this.apiKeyOpen = !this.apiKeyOpen; this.apiKeyDraft = this.apiKey; }

    async handleApiKeySave() {
        const val = (this.apiKeyDraft || '').trim();
        this.busy = true;
        try {
            await saveGoogleApiKey({ apiKey: val });
            this.apiKey = val;
            this.apiKeyDraft = val;
            this.apiKeyOpen = false;
            this.setMessage(
                val ? 'Google API key saved. Try Choose folder again.' : 'Google API key cleared.',
                val ? 'success' : 'info'
            );
        } catch (e) {
            this.setMessage('Could not save the API key: ' + this.errMsg(e), 'error');
        } finally {
            this.busy = false;
        }
    }

    /* ── CSP trusted sites ───────────────────────────────────────────────
       The Picker loads from several Google domains. If the org has not trusted
       them the browser blocks the frame and the Picker comes up blank with no
       error - so check up front and say so plainly instead. */

    async checkTrustedSites() {
        if (!this.usePicker) return;
        try {
            const st = await getPickerTrustedSites();
            this.missingSites = (st && st.missing) || [];
        } catch (e) {
            this.missingSites = [];   // unreadable: stay quiet rather than cry wolf
        }
    }

    get hasMissingSites() { return this.missingSites.length > 0; }
    get missingSitesText() { return this.missingSites.join(', '); }
    get missingSitesCount() { return this.missingSites.length; }
}