import { LightningElement, api, track, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import bulkSend from '@salesforce/apex/AgreementController.bulkSend';
import { stripNs } from 'c/nsUtils';
// LMS: tell the signer manager (and other siblings) to refresh after a bulk add.
import { publish, MessageContext } from 'lightning/messageService';
import SIGNFORCE_REFRESH from '@salesforce/messageChannel/SignForceRefresh__c';

// The only recipient roles the Signer__c.Role__c picklist accepts.
const VALID_ROLES = { signer: 'Signer', approver: 'Approver', cc: 'CC' };

export default class BulkSendSigners extends LightningElement {
    @api recordId;
    @wire(MessageContext) messageContext;
    @track pastedData = '';
    @track uploadedFileName = '';
    @track parsedSigners = [];
    @track isAdding = false;
    @track showResult = false;
    @track resultMessage = '';

    get parseBtnDisabled() {
        return !this.pastedData || this.pastedData.trim().length === 0;
    }

    triggerUpload() {
        this.template.querySelector('input[type="file"]').click();
    }

    handleFileUpload(event) {
        const file = event.target.files[0];
        if (!file) return;
        const reader = new FileReader();
        reader.onload = (e) => {
            // CSV of name,email,role — markup characters have no legitimate use
            // here, so strip them on the way into the tracked property.
            this.pastedData = String(e.target.result || '').replace(/[<>&`]/g, '');
            this.uploadedFileName = String(file.name || '').replace(/[<>&`]/g, '');
            this.handleParse();
            this.dispatchEvent(new ShowToastEvent({
                title: 'File loaded',
                message: file.name + ' — data filled in below, review and click Add Signers.',
                variant: 'success'
            }));
        };
        reader.readAsText(file);
    }

    handlePastedData(event) {
        this.pastedData = String(event.target.value || '').replace(/[<>&`]/g, '');
    }

    handleParse() {
        if (!this.pastedData) return;
        const lines = this.pastedData.trim().split('\n');
        const signers = [];
        let num = 1;

        for (const line of lines) {
            const trimmed = line.trim();
            if (!trimmed) continue;

            // Skip header row
            if (trimmed.toLowerCase().startsWith('name') || trimmed.toLowerCase().startsWith('full name')) continue;

            const parts = trimmed.split(',').map(p => p.trim().replace(/"/g, ''));
            if (parts.length < 2) continue;

            const name = parts[0];
            const email = parts[1];
            // BUG-020 FIX: a CSV role that isn't a real picklist value used to be
            // passed straight through and blow up the insert. Normalise it
            // (case-insensitive) and fall back to Signer for anything unknown.
            const role = this._normalizeRole(parts.length > 2 ? parts[2] : 'Signer');
            const order = parts.length > 3 ? parseInt(parts[3]) : num;

            if (!name || !email || !email.includes('@')) continue;

            signers.push({
                key: 'sig-' + num + '-' + Date.now(),
                num: num,
                name: name,
                email: email,
                role: role || 'Signer',
                order: order
            });
            num++;
        }

        this.parsedSigners = signers;
        if (signers.length === 0) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'No valid signers found',
                message: 'Check the format: Name, Email, Role (optional)',
                variant: 'warning'
            }));
        }
    }

    _normalizeRole(raw) {
        const key = (raw || '').trim().toLowerCase().replace(/\s+only$/, '');
        return VALID_ROLES[key] || 'Signer';
    }

    handleRemoveSigner(event) {
        const idx = parseInt(event.currentTarget.dataset.index);
        this.parsedSigners = this.parsedSigners.filter((_, i) => i !== idx)
            .map((s, i) => ({ ...s, num: i + 1 }));
    }

    handleClear() {
        this.parsedSigners = [];
        this.pastedData = '';
        this.showResult = false;
    }

    async handleBulkAdd() {
        if (this.parsedSigners.length === 0) return;
        this.isAdding = true;
        try {
            const signersData = this.parsedSigners.map(s => ({
                name: s.name,
                email: s.email,
                role: s.role,
                order: s.order
            }));

            const result = stripNs(await bulkSend({
                agreementId: this.recordId,
                signersJson: JSON.stringify(signersData)
            }));

            this.showResult = true;
            this.resultMessage = result.successCount + ' signers added successfully' +
                (result.failCount > 0 ? ', ' + result.failCount + ' failed' : '');

            this.dispatchEvent(new ShowToastEvent({
                title: 'Bulk Add Complete',
                message: this.resultMessage,
                variant: result.failCount > 0 ? 'warning' : 'success'
            }));

            // BUG-019 FIX: tell the signer manager to reload so the newly added
            // signers appear without a manual page refresh.
            if (result.successCount > 0) {
                try {
                    publish(this.messageContext, SIGNFORCE_REFRESH, {
                        recordId: this.recordId,
                        source: 'bulk'
                    });
                } catch (e) { /* LMS best-effort */ }
            }

            this.parsedSigners = [];
            this.pastedData = '';

        } catch(e) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Error',
                message: e.body?.message || 'Bulk add failed',
                variant: 'error'
            }));
        } finally {
            this.isAdding = false;
        }
    }
}