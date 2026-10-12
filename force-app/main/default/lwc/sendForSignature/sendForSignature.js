import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import createAgreement from '@salesforce/apex/AgreementController.createAgreement';
import addSigner from '@salesforce/apex/AgreementController.addSigner';
import sendForSignatureWithCustomEmail from '@salesforce/apex/AgreementController.sendForSignatureWithCustomEmail';

export default class SendForSignature extends LightningElement {
    // Steps
    @track step1 = true;
    @track step2 = false;
    @track step3 = false;
    @track isLoading = false;

    // Step 1 - details
    @track agreementName = '';
    @track agreementType = 'Other';
    @track signingOrder  = 'Sequential';
    @track expiryDate;
    @track message = '';

    // Step 2 - signers
    @track signers = [{ key: '1', name: '', email: '', role: 'Signer', order: 1 }];

    // Step 3 - email customization
    @track emailSubject = '';
    @track emailMessage = '';

    agreementId;

    typeOptions = [
        { label: 'NDA', value: 'NDA' }, { label: 'Contract', value: 'Contract' },
        { label: 'Proposal', value: 'Proposal' }, { label: 'Invoice', value: 'Invoice' },
        { label: 'HR Document', value: 'HR Document' }, { label: 'Other', value: 'Other' }
    ];
    orderOptions = [
        { label: 'Sequential (one at a time)', value: 'Sequential' },
        { label: 'Parallel (all at once)',     value: 'Parallel' }
    ];
    roleOptions = [
        { label: 'Signer',   value: 'Signer' },
        { label: 'CC Only',  value: 'CC' }
    ];

    /* ── getters ──────────────────────────────────────── */
    get stepTitle() {
        if (this.step1) return 'Agreement details';
        if (this.step2) return 'Add signers';
        return 'Email invitation';
    }
    get step1Class() { return 'sf-step ' + (this.step1 ? 'sf-step-active' : (this.step2 || this.step3 ? 'sf-step-done' : '')); }
    get step2Class() { return 'sf-step ' + (this.step2 ? 'sf-step-active' : (this.step3 ? 'sf-step-done' : '')); }
    get step3Class() { return 'sf-step ' + (this.step3 ? 'sf-step-active' : ''); }
    get showBack()   { return this.step2 || this.step3; }

    get defaultSubjectPlaceholder() {
        const n = this.agreementName || 'this document';
        return 'Action Required: Please sign "' + n + '"';
    }
    get effectiveSubject() {
        return this.emailSubject && this.emailSubject.trim()
            ? this.emailSubject.trim()
            : this.defaultSubjectPlaceholder;
    }
    get effectiveMessageDisplay() {
        if (this.emailMessage && this.emailMessage.trim()) return this.emailMessage.trim();
        if (this.message && this.message.trim()) return this.message.trim();
        return '(Default invitation text will be used.)';
    }

    /* ── change handlers ──────────────────────────────── */
    handleNameChange(e)         { this.agreementName = e.target.value; }
    handleTypeChange(e)         { this.agreementType = e.target.value; }
    handleOrderChange(e)        { this.signingOrder  = e.target.value; }
    handleExpiryChange(e)       { this.expiryDate    = e.target.value; }
    handleMessageChange(e)      { this.message       = e.target.value; }
    handleSubjectChange(e)      { this.emailSubject  = e.target.value; }
    handleEmailMessageChange(e) { this.emailMessage  = e.target.value; }

    handleSignerChange(e) {
        const idx   = parseInt(e.target.dataset.index, 10);
        const field = e.target.dataset.field;
        const signers = JSON.parse(JSON.stringify(this.signers));
        signers[idx][field] = e.target.value;
        this.signers = signers.map((s, i) => ({ ...s, displayOrder: i + 1 }));
    }

    addSigner() {
        const next = [...this.signers, {
            key: Date.now().toString(), name: '', email: '',
            role: 'Signer', order: this.signers.length + 1
        }];
        this.signers = next.map((s, i) => ({ ...s, displayOrder: i + 1 }));
    }

    removeSigner(e) {
        const idx = parseInt(e.currentTarget.dataset.index, 10);
        const next = this.signers.filter((_, i) => i !== idx);
        this.signers = next.map((s, i) => ({ ...s, displayOrder: i + 1 }));
    }

    /* ── step navigation ──────────────────────────────── */
    handleNext() {
        if (this.step1) {
            if (!this.agreementName) {
                this.showToast('Required', 'Agreement name is required', 'warning');
                return;
            }
            this.step1 = false;
            this.step2 = true;
            return;
        }
        if (this.step2) {
            // Validate at least one signer with email.
            const ok = this.signers.some(s => s.email && s.email.trim());
            if (!ok) {
                this.showToast('Required', 'Add at least one signer with an email address.', 'warning');
                return;
            }
            // BUG-008 FIX: each signer's email must be non-blank AND valid format
            // (mirrors createAgreement.js validation).
            const emailRe = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
            for (const s of this.signers) {
                const emailTrim = (s.email || '').trim();
                if (!emailTrim || !emailRe.test(emailTrim)) {
                    this.showToast('Invalid email', `"${s.email}" is not a valid email address`, 'error');
                    return;
                }
            }
            this.step2 = false;
            this.step3 = true;
        }
    }

    handleBack() {
        if (this.step3) { this.step3 = false; this.step2 = true; return; }
        if (this.step2) { this.step2 = false; this.step1 = true; }
    }

    /* ── create + send ────────────────────────────────── */
    async handleCreateAndSend() {
        this.isLoading = true;
        try {
            const agrId = await createAgreement({
                name:           this.agreementName,
                agreementType:  this.agreementType,
                signingOrder:   this.signingOrder,
                message:        this.message,
                expiryDate:     this.expiryDate
            });
            this.agreementId = agrId;

            for (const s of this.signers) {
                if (s.email) {
                    await addSigner({
                        agreementId: agrId,
                        signerName:  s.name,
                        email:       s.email,
                        role:        s.role,
                        order:       s.order
                    });
                }
            }

            // Pass through custom subject/message if provided; blank values are
            // normalized server-side to fall back to default behaviour.
            await sendForSignatureWithCustomEmail({
                agreementId:  agrId,
                emailSubject: (this.emailSubject || '').trim(),
                emailMessage: (this.emailMessage || '').trim()
            });

            this.showToast('Success', 'Agreement sent for signature!', 'success');
            this.dispatchEvent(new CustomEvent('created'));
        } catch (e) {
            this.showToast('Error', e.body?.message || 'Something went wrong', 'error');
        } finally {
            this.isLoading = false;
        }
    }

    async handleSaveDraft() {
        this.isLoading = true;
        try {
            const agrId = await createAgreement({
                name:          this.agreementName,
                agreementType: this.agreementType,
                signingOrder:  this.signingOrder,
                message:       this.message,
                expiryDate:    this.expiryDate
            });
            for (const s of this.signers) {
                if (s.email) {
                    await addSigner({
                        agreementId: agrId,
                        signerName:  s.name,
                        email:       s.email,
                        role:        s.role,
                        order:       s.order
                    });
                }
            }
            this.showToast('Saved', 'Agreement saved as Draft', 'success');
            this.dispatchEvent(new CustomEvent('created'));
        } catch (e) {
            this.showToast('Error', e.body?.message || 'Something went wrong', 'error');
        } finally {
            this.isLoading = false;
        }
    }

    handleClose() { this.dispatchEvent(new CustomEvent('close')); }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    connectedCallback() {
        // Initial displayOrder annotation
        this.signers = this.signers.map((s, i) => ({ ...s, displayOrder: i + 1 }));
    }
}