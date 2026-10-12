import { LightningElement, api, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getVisibilityMatrix from '@salesforce/apex/DocumentVisibilityController.getVisibilityMatrix';
import updateVisibility from '@salesforce/apex/DocumentVisibilityController.updateVisibility';
import { stripNs } from 'c/nsUtils';

export default class DocumentVisibility extends LightningElement {
    @api recordId;
    @track isLoading = true;
    @track documents = [];
    @track signers = [];

    connectedCallback() {
        this.loadData();
    }

    get hasData() {
        return this.documents.length > 0 && this.signers.length > 0;
    }

    async loadData() {
        this.isLoading = true;
        try {
            const data = stripNs(await getVisibilityMatrix({ agreementId: this.recordId }));
            this.signers = data.signers || [];

            const matrix = data.matrix || [];
            const matrixMap = {};
            for (const cell of matrix) {
                const key = cell.docId + ':' + cell.signerId;
                matrixMap[key] = cell.canView;
            }

            this.documents = (data.documents || []).map(doc => {
                const signerAccess = this.signers.map(s => {
                    const key = doc.id + ':' + s.id;
                    const canView = matrixMap[key] !== undefined ? matrixMap[key] : true;
                    return {
                        key: key,
                        docId: doc.id,
                        signerId: s.id,
                        canView: canView,
                        btnClass: canView ? 'vis-toggle vis-toggle-on' : 'vis-toggle vis-toggle-off',
                        title: canView ? s.name + ' can view' : s.name + ' cannot view'
                    };
                });
                return { ...doc, signerAccess };
            });

        } catch(e) {
            console.error('Visibility load error:', e);
        } finally {
            this.isLoading = false;
        }
    }

    async handleToggle(event) {
        const docId = event.currentTarget.dataset.doc;
        const signerId = event.currentTarget.dataset.signer;

        // Find current state and toggle
        let newValue = true;
        this.documents = this.documents.map(doc => {
            if (doc.id === docId) {
                const updatedAccess = doc.signerAccess.map(a => {
                    if (a.signerId === signerId) {
                        newValue = !a.canView;
                        return {
                            ...a,
                            canView: newValue,
                            btnClass: newValue ? 'vis-toggle vis-toggle-on' : 'vis-toggle vis-toggle-off',
                            title: newValue ? a.title.replace('cannot', 'can') : a.title.replace(' can view', ' cannot view')
                        };
                    }
                    return a;
                });
                return { ...doc, signerAccess: updatedAccess };
            }
            return doc;
        });

        try {
            await updateVisibility({
                documentId: docId,
                signerId: signerId,
                canView: newValue
            });
        } catch(e) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Error',
                message: 'Failed to update visibility',
                variant: 'error'
            }));
            this.loadData(); // Reload on error
        }
    }
}