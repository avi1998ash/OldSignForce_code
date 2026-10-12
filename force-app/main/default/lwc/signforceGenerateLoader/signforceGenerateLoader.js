import { LightningElement, api } from 'lwc';

/**
 * signforceGenerateLoader — the wait while a document is being produced.
 *
 * Merge tags fly in from the left and turn into text on the page, which is
 * literally what the server is doing: reading the record, dropping its values
 * into the template, and building the file.
 *
 * WHY A FULL OVERLAY. Generating makes an HTTP callout, so the wait is seconds
 * rather than milliseconds. A small inline spinner left the rest of the screen
 * live, and a second click on Generate during that window starts a second
 * document. This covers the panel — including its Generate button — so there is
 * nothing left there to click. See the .gl-veil comment for why it stops at the
 * panel rather than the viewport.
 *
 * NO PERCENTAGE ANYWHERE. Generation is one Apex call ending in one callout;
 * the server reports nothing back until it is finished. A progress number here
 * would be invented, so the bar is indeterminate and the message says what is
 * happening rather than how far along it is.
 */
export default class SignforceGenerateLoader extends LightningElement {

    @api visible = false;

    /** Headline. Defaults to the document case; callers creating an agreement
     *  pass their own so the wording matches what they will end up with. */
    @api title = 'Building your document';

    @api message = 'Reading the record and filling in the template. This takes a few seconds.';

    /**
     * Holds the panel still while the document is being built.
     *
     * The veil covers the panel, but the Salesforce modal around it keeps its
     * own scrollbar, so the form behind could still be scrolled during the wait
     * — the loader stayed put while its own context slid away underneath.
     *
     * That scroll container is outside this component, so CSS cannot reach it.
     * Blocking the wheel and touch events on the veil itself is what stops the
     * scroll, and the listeners are added in JS rather than in the template
     * because a wheel handler must be registered with { passive: false } before
     * preventDefault() has any effect.
     */
    _veil = null;
    _block = (e) => e.preventDefault();

    renderedCallback() {
        const veil = this.template.querySelector('.gl-veil');

        if (veil && veil !== this._veil) {
            this._detach();
            this._veil = veil;
            veil.addEventListener('wheel', this._block, { passive: false });
            veil.addEventListener('touchmove', this._block, { passive: false });
        } else if (!veil && this._veil) {
            this._detach();
        }
    }

    disconnectedCallback() {
        this._detach();
    }

    _detach() {
        if (!this._veil) return;
        this._veil.removeEventListener('wheel', this._block);
        this._veil.removeEventListener('touchmove', this._block);
        this._veil = null;
    }

    /* The chip labels live here rather than in the markup: written literally in
       the template, {{Name}} is read as an expression binding and the bundle
       fails to compile ("Unexpected token ."). Text interpolated from JS is
       never re-parsed, so the braces survive. */
    tagOne = '{{Name}}';
    tagTwo = '{{Amount}}';
    tagThree = '{{Date}}';
}