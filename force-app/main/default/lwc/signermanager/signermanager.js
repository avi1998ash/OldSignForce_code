import { LightningElement, api, track, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { refreshApex } from '@salesforce/apex';
import { NavigationMixin } from 'lightning/navigation';
import getSigners from '@salesforce/apex/AgreementController.getSigners';
import addSigner from '@salesforce/apex/AgreementController.addSigner';
import updateSigner from '@salesforce/apex/AgreementController.updateSigner';
import deleteSigner from '@salesforce/apex/AgreementController.deleteSigner';
import resendSignerEmail from '@salesforce/apex/AgreementController.resendSignerEmail';
import getAgreementDetail from '@salesforce/apex/AgreementController.getAgreementDetail';
import voidAgreement from '@salesforce/apex/AgreementController.voidAgreement';
import sendReminder from '@salesforce/apex/AgreementController.sendReminder';
import sendBulkReminders from '@salesforce/apex/AgreementController.sendBulkReminders';
import saveAsTemplate from '@salesforce/apex/AgreementController.saveAsTemplate';
import startInPersonSigning from '@salesforce/apex/AgreementController.startInPersonSigning';
import searchExistingSigners from '@salesforce/apex/AgreementController.searchExistingSigners';
import { stripNs } from 'c/nsUtils';
// LMS: tell sibling components (e.g. documentEditor) to refresh when signers change.
import { publish, subscribe, unsubscribe, MessageContext } from 'lightning/messageService';
import SIGNFORCE_REFRESH from '@salesforce/messageChannel/SignForceRefresh__c';

const COLORS = ['#0a1628', '#7c3aed', '#0891b2', '#059669', '#d97706', '#dc2626', '#7c2d12', '#4338ca'];

// In-person signing now opens the public site signing page (result.signingUrl) for every
// context, so internal users no longer run the guest signing component or GuestSigningApi.
// The internal-tab branch in handleInPersonSign is kept, unreachable, and is re-enabled by
// setting this to true.
const IN_PERSON_INTERNAL_TAB_ENABLED = false;

export default class SignerManager extends NavigationMixin(LightningElement) {
    @api recordId;
    @wire(MessageContext) messageContext;

    _refreshSub;

    // BUG-019 FIX: refresh the signer grid when a sibling (e.g. Bulk Add Signers)
    // reports it changed the recipients — otherwise the table only updated on a
    // manual page refresh. We ignore our own 'signers' messages to avoid a loop.
    connectedCallback() {
        try {
            this._refreshSub = subscribe(this.messageContext, SIGNFORCE_REFRESH, (msg) => {
                if (!msg) return;
                if (msg.recordId && msg.recordId !== this.recordId) return;
                if (msg.source === 'signers') return;
                if (this.wiredSignersResult) refreshApex(this.wiredSignersResult);
                // Status drives canEdit/canVoid — refresh it too, or the panel
                // keeps offering Add/Edit from a pre-send cached 'Draft'.
                if (this.wiredAgreementResult) refreshApex(this.wiredAgreementResult);
            });
        } catch (e) { /* LMS is best-effort UI sugar */ }

        // In-person signing finishes in another tab: it posts back when the
        // signature lands (and the window-focus fallback covers a blocked
        // message), so this page refreshes without a manual reload.
        this._onInPersonMsg = (evt) => {
            if (evt && evt.data && evt.data.type === 'signforce_inperson_done') {
                this.refreshAfterInPerson();
            }
        };
        window.addEventListener('message', this._onInPersonMsg);
        this._onWindowFocus = () => this.refreshAfterInPerson();
        window.addEventListener('focus', this._onWindowFocus);
    }

    disconnectedCallback() {
        if (this._refreshSub) { unsubscribe(this._refreshSub); this._refreshSub = null; }
        if (this._onInPersonMsg) { window.removeEventListener('message', this._onInPersonMsg); this._onInPersonMsg = null; }
        if (this._onWindowFocus) { window.removeEventListener('focus', this._onWindowFocus); this._onWindowFocus = null; }
    }

    // Broadcast a "signers changed" message so documentEditor (and any other
    // sibling on the record page) reloads its signer list.
    notifySignersChanged() {
        try {
            publish(this.messageContext, SIGNFORCE_REFRESH, {
                recordId: this.recordId,
                source: 'signers'
            });
        } catch (e) {
            // LMS is best-effort UI sugar — never let it break the save flow.
        }
    }
    @track isLoading = true;
    @track showModal = false;
    @track isSaving = false;
    @track editingId = null;
    @track showInPersonModal = false;
    @track inPersonUrl = '';
    @track inPersonSignerName = '';

    // Form fields
    @track formName = '';
    @track formEmail = '';
    @track formRole = 'Signer';
    @track formOrder = 1;

    @track searchTerm = '';
    @track suggestions = [];
    @track showSuggestions = false;

    wiredSignersResult;
    wiredAgreementResult;
    agreementStatus = '';
    agreementName = '';

    roleOptions = [
        { label: 'Signer', value: 'Signer' },
        { label: 'CC Only', value: 'CC' }
    ];

    @wire(getAgreementDetail, { agreementId: '$recordId' })
    wiredAgreement(result) {
        this.wiredAgreementResult = result;
        if (result.data) {
            const detail = stripNs(result.data);
            this.agreementStatus = detail.Status__c;
            this.agreementName = detail.Name;
        }
    }

    @wire(getSigners, { agreementId: '$recordId' })
    wiredSigners(result) {
        this.wiredSignersResult = result;
        this.isLoading = false;
    }

    // BUG-023 FIX: recipients are locked once the agreement is sent. Adding,
    // editing or deleting signers is only allowed in Draft — the same rule
    // e-signature tools enforce so the audit trail can't shift under a sent
    // envelope. (Void / Remind / Resend / In-Person stay available on Sent via
    // their own getters.)
    get canEdit() {
        return this.agreementStatus === 'Draft';
    }

    get canVoid() {
        return this.agreementStatus === 'Sent';
    }

    // BUG-016 FIX: toasts/dialogs used to say "Signer" for every recipient. Map
    // the role to its human word so CC actions read "CC added" / "CC removed".
    _partyWord(role) {
        if (role === 'CC') return 'CC';
        if (role === 'Approver') return 'Approver';
        return 'Signer';
    }

    get canRemindAll() {
        return this.agreementStatus === 'Sent' && this.hasPendingSigners;
    }

    get canSaveTemplate() {
        return this.signers.length > 0;
    }

    get hasPendingSigners() {
        // BUG-058 FIX: ignore CC-Only recipients so a fully-signed agreement
        // with a still-pending CC does not report outstanding signers / keep
        // 'Remind All' active. Only true signers count toward "pending".
        return this.signers.some(s =>
            (!s.Role__c || s.Role__c === 'Signer') &&
            (s.Status__c === 'Sent' || s.Status__c === 'Pending'));
    }

    // BUG-041 FIX: derived view of the signing grid that excludes CC-Only
    // recipients (Role__c === 'CC'), so CC contacts no longer appear as
    // signers with Resend/Remind/In-Person actions.
    get signerRows() {
        return this.signers.filter(s => !s.Role__c || s.Role__c === 'Signer');
    }

    // BUG-041 FIX: CC-Only recipients kept visible/manageable in a separate
    // section, but OUT of the signing grid.
    get ccRows() {
        return this.signers.filter(s => s.Role__c === 'CC');
    }

    get signers() {
        if (!this.wiredSignersResult?.data) return [];
        return stripNs(this.wiredSignersResult.data).map((s, idx) => {
            const color = COLORS[idx % COLORS.length];
            const initials = (s.Name || '??').substring(0, 2).toUpperCase();
            const isSigned = s.Status__c === 'Signed';
            // Remind/resend only after the agreement is actually SENT — before
            // that the signer has no access token, and the reminder email would
            // carry a token=null link ("Invalid signing link").
            const agreementSent = this.agreementStatus === 'Sent';
            const canResend = agreementSent && (s.Status__c === 'Sent' || s.Status__c === 'Pending');
            const canRemind = canResend;

            let statusClass = 'sm-status sm-status-pending';
            if (s.Status__c === 'Signed') statusClass = 'sm-status sm-status-signed';
            else if (s.Status__c === 'Sent') statusClass = 'sm-status sm-status-sent';
            else if (s.Status__c === 'Declined') statusClass = 'sm-status sm-status-declined';
            else if (s.Status__c === 'Voided') statusClass = 'sm-status sm-status-voided';

            const signedDateFormatted = s.Signed_Date__c
                ? new Date(s.Signed_Date__c).toLocaleDateString()
                : '';

            return {
                ...s,
                initials,
                avatarStyle: `background:${color};`,
                statusClass,
                isSigned,
                canResend,
                canRemind,
                signedDateFormatted
            };
        });
    }

    get modalTitle() {
        return this.editingId ? 'Edit Signer' : 'Add Signer';
    }

    get saveLabel() {
        return this.editingId ? 'Update' : 'Add Signer';
    }

    async handleInPersonSign(event) {
        const id = event.currentTarget.dataset.id;
        this.isLoading = true;
        try {
            const result = await startInPersonSigning({ signerId: id });
            // Inside Lightning, sign on the internal tab as the logged-in user;
            // in a community (or anywhere else), keep the site's signing page.
            const isLightning = window.location.pathname.indexOf('/lightning/') === 0;
            if (IN_PERSON_INTERNAL_TAB_ENABLED && isLightning && result.internalCmpName) {
                // URL-addressable component page: renders signingViewer full-page
                // with no tab header band and no temp-nav-item involved.
                try {
                    this.inPersonUrl = await this[NavigationMixin.GenerateUrl]({
                        type: 'standard__component',
                        attributes: { componentName: result.internalCmpName },
                        state: { c__token: result.token, c__inperson: '1' }
                    });
                } catch (e) {
                    this.inPersonUrl = result.internalUrl || result.signingUrl;
                }
            } else {
                this.inPersonUrl = result.signingUrl;
            }
            this.inPersonSignerName = result.signerName;
            this.showInPersonModal = true;
        } catch (e) {
            this.toast('Error', e.body?.message || 'Failed to start in-person signing', 'error');
        } finally {
            this.isLoading = false;
        }
    }

    handleCloseInPerson() {
        this.showInPersonModal = false;
        this.inPersonUrl = '';
    }

    handleOpenInPerson() {
        // The anchor's own target=_blank navigation opens the tab — no
        // window.open, so popup blockers stay out of the way.
        this.showInPersonModal = false;
        // The signing tab announces completion via postMessage and closes itself;
        // the focus flag is the fallback for browsers that block the message.
        this._inPersonOpen = true;
    }

    refreshAfterInPerson() {
        if (!this._inPersonOpen) return;
        this._inPersonOpen = false;
        if (this.wiredSignersResult) refreshApex(this.wiredSignersResult);
        if (this.wiredAgreementResult) refreshApex(this.wiredAgreementResult);
        this.notifySignersChanged();
    }

    // ═══════ Modal Handlers ═══════

    handleShowAdd() {
        this.editingId = null;
        this.formName = '';
        this.formEmail = '';
        this.formRole = 'Signer';
        this.formOrder = this.signers.length + 1;
        this.searchTerm = '';
        this.suggestions = [];
        this.showSuggestions = false;
        this.showModal = true;
    }

    handleEdit(event) {
        const id = event.currentTarget.dataset.id;
        const signer = this.signers.find(s => s.Id === id);
        if (!signer) return;
        this.editingId = id;
        this.formName = signer.Name;
        this.formEmail = signer.Email__c;
        this.formRole = signer.Role__c;
        this.formOrder = signer.Signing_Order__c;
        this.searchTerm = '';
        this.suggestions = [];
        this.showSuggestions = false;
        this.showModal = true;
    }

    handleCloseModal() {
        this.showModal = false;
        this.editingId = null;
    }

    /* ── Existing-signer search ── */

    handleSearchChange(e) {
        const term = (e.target.value || '').trim();
        this.searchTerm = term;
        // The search box is only for finding an existing signer; it no longer
        // mirrors into Full Name. Coupling them meant clearing the search wiped
        // the name the user had picked. Full Name has its own input, and picking
        // a suggestion still fills it (handleSuggestionClick).

        clearTimeout(this._searchTimer);
        if (term.length < 2) {
            this.suggestions = [];
            this.showSuggestions = false;
            return;
        }
        this._searchTimer = setTimeout(async () => {
            try {
                const results = await searchExistingSigners({ searchTerm: term });
                this.suggestions = results || [];
                this.showSuggestions = this.suggestions.length > 0;
            } catch (err) {
                console.error('Signer search failed:', err);
            }
        }, 300);
    }

    /** See createAgreement.handleSuggestionMouseDown — keeps focus so the click lands. */
    handleSuggestionMouseDown(e) {
        e.preventDefault();
    }

    handleSuggestionClick(e) {
        const sIdx = parseInt(e.currentTarget.dataset.sidx, 10);
        const pick = this.suggestions[sIdx];
        if (!pick) return;

        this.formName = pick.name;
        this.formEmail = pick.email;
        this.formRole = pick.role || 'Signer';
        this.searchTerm = pick.name;
        this.suggestions = [];
        this.showSuggestions = false;
    }

    handleSearchBlur() {
        setTimeout(() => { this.showSuggestions = false; }, 200);
    }

    handleSearchFocus() {
        if (this.suggestions && this.suggestions.length > 0) {
            this.showSuggestions = true;
        }
    }

    handleFormName(e) { this.formName = e.target.value; }
    handleFormEmail(e) { this.formEmail = e.target.value; }
    handleFormRole(e) { this.formRole = e.target.value; }
    handleFormOrder(e) { this.formOrder = parseInt(e.target.value) || 1; }

    async handleSave() {
        // BUG-027 FIX: previously this only checked blank — accepted whitespace
        // and any garbage like "abc", "abc@", "abc@def" as a valid email.
        // Now we trim, reject blanks, and require RFC-ish email shape.
        const nameTrim = (this.formName || '').trim();
        const emailTrim = (this.formEmail || '').trim();
        if (!nameTrim) {
            this.toast('Error', 'Name is required', 'error');
            return;
        }
        if (!emailTrim) {
            this.toast('Error', 'Email is required', 'error');
            return;
        }
        // Matches one-or-more chars, @, one-or-more chars, ., one-or-more chars.
        // Same regex used in createAgreement to keep validation consistent.
        const emailRe = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
        if (!emailRe.test(emailTrim)) {
            this.toast('Invalid email', `"${emailTrim}" is not a valid email address`, 'error');
            return;
        }
        // Normalize back so server gets the trimmed values
        this.formName = nameTrim;
        this.formEmail = emailTrim;

        this.isSaving = true;
        try {
            if (this.editingId) {
                await updateSigner({
                    signerId: this.editingId,
                    signerName: this.formName,
                    email: this.formEmail,
                    role: this.formRole,
                    orderNum: this.formOrder
                });
                this.toast('Updated', `${this._partyWord(this.formRole)} updated successfully`, 'success');
            } else {
                await addSigner({
                    agreementId: this.recordId,
                    signerName: this.formName,
                    email: this.formEmail,
                    role: this.formRole,
                    orderNum: this.formOrder
                });
                this.toast('Added', `${this._partyWord(this.formRole)} added successfully`, 'success');
            }
            this.showModal = false;
            this.editingId = null;
            await refreshApex(this.wiredSignersResult);
            this.notifySignersChanged();
        } catch (e) {
            this.toast('Error', e.body?.message || 'Something went wrong', 'error');
        } finally {
            this.isSaving = false;
        }
    }

    async handleDelete(event) {
        const id = event.currentTarget.dataset.id;
        // Capture the role NOW — after deleteSigner the wired list still holds the
        // old row, but grabbing it up front keeps the toast wording correct.
        const removed = (this.signers || []).find(s => s.Id === id);
        const word = this._partyWord(removed && removed.Role__c);
        const ok = await this._dialog().open({
            title: `Remove this ${word.toLowerCase()}?`,
            message: word === 'CC'
                ? "They'll be taken off the agreement and won't be copied on it."
                : "They'll be taken off the agreement and won't be asked to sign.",
            confirmLabel: 'Remove',
            variant: 'danger'
        });
        if (!ok) return;
        this.isLoading = true;
        try {
            await deleteSigner({ signerId: id });
            this.toast('Removed', `${word} removed`, 'success');
            await refreshApex(this.wiredSignersResult);
            this.notifySignersChanged();
        } catch (e) {
            this.toast('Error', e.body?.message || 'Delete failed', 'error');
        } finally {
            this.isLoading = false;
        }
    }

    // ═══════ New Phase 3 Actions ═══════

    async handleResend(event) {
        const id = event.currentTarget.dataset.id;
        try {
            await resendSignerEmail({ signerId: id });
            this.toast('Sent', 'Signing email resent with fresh link', 'success');
        } catch (e) {
            this.toast('Error', e.body?.message || 'Resend failed', 'error');
        }
    }

    async handleRemind(event) {
        const id = event.currentTarget.dataset.id;
        try {
            await sendReminder({ signerId: id });
            this.toast('Sent', 'Reminder email sent', 'success');
        } catch (e) {
            this.toast('Error', e.body?.message || 'Reminder failed', 'error');
        }
    }

    async handleRemindAll() {
        const ok = await this._dialog().open({
            title: 'Send a reminder?',
            message: 'Everyone who still has to sign gets another email with their link.',
            confirmLabel: 'Send reminder'
        });
        if (!ok) return;
        try {
            await sendBulkReminders({ agreementId: this.recordId });
            this.toast('Sent', 'Reminders sent to all pending signers', 'success');
        } catch (e) {
            this.toast('Error', e.body?.message || 'Bulk reminder failed', 'error');
        }
    }

    async handleVoid() {
        const reason = await this._dialog().open({
            title: 'Void this agreement?',
            message: 'Signing links stop working immediately and every signer is notified. This cannot be undone.',
            input: true,
            placeholder: 'Reason for voiding',
            required: true,
            confirmLabel: 'Void agreement',
            variant: 'danger'
        });
        if (reason === null) return;
        this.isLoading = true;
        try {
            await voidAgreement({ agreementId: this.recordId, reason: reason });
            this.toast('Voided', 'Agreement has been voided. All signers have been notified.', 'success');
            await refreshApex(this.wiredAgreementResult);
            await refreshApex(this.wiredSignersResult);
            this.notifySignersChanged();
        } catch (e) {
            this.toast('Error', e.body?.message || 'Void failed', 'error');
        } finally {
            this.isLoading = false;
        }
    }

    async handleSaveAsTemplate() {
        const name = await this._dialog().open({
            title: 'Save as template',
            message: 'Reuse this agreement’s signers and fields on future documents.',
            input: true,
            placeholder: 'Template name',
            defaultValue: this.agreementName + ' Template',
            required: true,
            confirmLabel: 'Save template'
        });
        if (!name) return;
        try {
            const templateId = await saveAsTemplate({ agreementId: this.recordId, templateName: name });
            this.toast('Saved', 'Template "' + name + '" created successfully', 'success');
        } catch (e) {
            this.toast('Error', e.body?.message || 'Template save failed', 'error');
        }
    }

    /** The themed confirm/prompt dropped at the end of this component's template. */
    _dialog() {
        return this.template.querySelector('c-signforce-confirm');
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}