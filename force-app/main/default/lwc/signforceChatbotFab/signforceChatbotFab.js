import { LightningElement, track } from 'lwc';
import isAgentforceAvailable from '@salesforce/apex/SignForceAccess.isAgentforceAvailable';

export default class SignforceChatbotFab extends LightningElement {
    @track isOpen = false;
    // Hidden until we confirm Agentforce is available — orgs without it never see the FAB.
    @track agentforceAvailable = false;

    connectedCallback() {
        isAgentforceAvailable()
            .then((ok) => { this.agentforceAvailable = !!ok; })
            .catch(() => { this.agentforceAvailable = false; });
    }

    toggleChat() {
        this.isOpen = !this.isOpen;
    }

    handleOverlayClick(event) {
        // Click on dark overlay closes the chat; click inside the window does not.
        if (event.target.classList && event.target.classList.contains('sf-chat-overlay')) {
            this.isOpen = false;
        }
    }

    stopPropagation(event) {
        event.stopPropagation();
    }
}