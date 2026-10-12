import { LightningElement, api, track } from 'lwc';

/**
 * signforceConfirm — the product's own confirm / prompt dialog.
 *
 * Replaces two things that both looked like they belonged to someone else:
 *   - the browser's native confirm()/prompt(), which is unstyleable, renders
 *     differently on every OS, and blocks the page; and
 *   - lightning/confirm, which is a Salesforce-blue SLDS modal.
 * Neither could carry SignForce's theme, and one of them was being shown to
 * external signers mid-signature.
 *
 * Usage — drop <c-signforce-confirm> once in the parent template, then:
 *
 *   const ok = await this.refs.confirm.open({
 *       title: 'Delete document?',
 *       message: 'This cannot be undone.',
 *       confirmLabel: 'Delete',
 *       variant: 'danger'
 *   });                                    // -> true | false
 *
 *   const reason = await this.refs.confirm.open({
 *       title: 'Decline to sign',
 *       message: 'Let the sender know why.',
 *       input: true,
 *       placeholder: 'Reason'
 *   });                                    // -> string | null  (null = cancelled)
 */
export default class SignforceConfirm extends LightningElement {
    @track isOpen = false;
    @track title = '';
    @track message = '';
    @track confirmLabel = 'Confirm';
    @track cancelLabel = 'Cancel';
    @track variant = 'brand';          // 'brand' | 'danger'
    @track hasInput = false;
    @track placeholder = '';
    @track inputValue = '';
    @track inputRequired = false;
    @track errorText = '';

    _resolve = null;

    @api
    open(config = {}) {
        this.title = config.title || 'Are you sure?';
        this.message = config.message || '';
        this.confirmLabel = config.confirmLabel || (config.input ? 'Submit' : 'Confirm');
        this.cancelLabel = config.cancelLabel || 'Cancel';
        this.variant = config.variant === 'danger' ? 'danger' : 'brand';
        this.hasInput = !!config.input;
        this.placeholder = config.placeholder || '';
        this.inputValue = config.defaultValue || '';
        this.inputRequired = !!config.required;
        this.errorText = '';
        this.isOpen = true;

        // Focus the primary control once the dialog paints, so keyboard users
        // land inside it rather than behind it.
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
            const el = this.template.querySelector(this.hasInput ? '.sfc-input' : '.sfc-confirm');
            if (el) el.focus();
        }, 0);

        return new Promise((resolve) => { this._resolve = resolve; });
    }

    get confirmClass() {
        return this.variant === 'danger'
            ? 'sfc-btn sfc-confirm sfc-btn_danger'
            : 'sfc-btn sfc-confirm sfc-btn_brand';
    }

    get showMessage() {
        return !!this.message;
    }

    handleInput(e) {
        this.inputValue = e.target.value;
        if (this.errorText) this.errorText = '';
    }

    handleConfirm() {
        if (this.hasInput && this.inputRequired && !String(this.inputValue || '').trim()) {
            this.errorText = 'Enter a value to continue.';
            return;
        }
        // A prompt answers with its text; a confirm answers true.
        this._close(this.hasInput ? String(this.inputValue || '').trim() : true);
    }

    handleCancel() {
        // Cancelling a prompt gives null, so callers can tell "no answer" apart
        // from an empty one; cancelling a confirm gives false.
        this._close(this.hasInput ? null : false);
    }

    handleKeydown(e) {
        if (e.key === 'Escape') {
            e.stopPropagation();
            this.handleCancel();
        } else if (e.key === 'Enter' && this.hasInput) {
            this.handleConfirm();
        }
    }

    // Clicks inside the card must not reach the backdrop's dismiss handler.
    stopPropagation(e) {
        e.stopPropagation();
    }

    _close(result) {
        this.isOpen = false;
        if (this._resolve) {
            const resolve = this._resolve;
            this._resolve = null;
            resolve(result);
        }
    }
}