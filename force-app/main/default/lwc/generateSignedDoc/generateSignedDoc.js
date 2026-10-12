import { LightningElement, api, wire } from 'lwc';
import { CloseActionScreenEvent } from 'lightning/actions';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { getRecord } from 'lightning/uiRecordApi';
import { vfPageUrl } from 'c/nsUtils';

export default class GenerateSignedDoc extends LightningElement {
    @api recordId;
    _hasOpened = false;

    @wire(getRecord, { recordId: '$recordId', fields: ['Agreement__c.Id'] })
    wiredRecord({ data }) {
        if (data && !this._hasOpened) {
            this._hasOpened = true;
            const url = vfPageUrl('StampedAgreementPDF') + '?agreementId=' + this.recordId;
            window.open(url, '_blank');

            this.dispatchEvent(new ShowToastEvent({
                title: 'Generating Signed Document',
                message: 'The signed document is being generated in a new tab.',
                variant: 'info'
            }));

            this.dispatchEvent(new CloseActionScreenEvent());
        }
    }
}