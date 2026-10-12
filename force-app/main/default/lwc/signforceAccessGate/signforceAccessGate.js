import { LightningElement, track } from 'lwc';
import hasAgreementAccess from '@salesforce/apex/SignForceAccess.hasAgreementAccess';

/**
 * Wraps an internal SignForce component's content and only renders it when the
 * running user has agreement access. Otherwise it shows a "contact your admin"
 * message. Guest/community signing components are intentionally never wrapped.
 *
 * Usage — wrap the component's whole template body:
 *   <template>
 *     <c-signforce-access-gate>
 *       ...existing markup...
 *     </c-signforce-access-gate>
 *   </template>
 *
 * While hidden, the slotted content is not rendered, so its child components do
 * not mount either.
 */
export default class SignforceAccessGate extends LightningElement {
    @track checking = true;
    @track denied = false;

    connectedCallback() {
        hasAgreementAccess()
            .then((ok) => {
                this.denied = !ok;
            })
            .catch(() => {
                // Fail closed: if the check errors, treat it as no access.
                this.denied = true;
            })
            .finally(() => {
                this.checking = false;
            });
    }

    get showContent() {
        return !this.checking && !this.denied;
    }
}