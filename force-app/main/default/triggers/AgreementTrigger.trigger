/**
 * AgreementTrigger - fires when an Agreement__c transitions to Completed.
 * All logic lives in AgreementTriggerHandler (testable directly); this body
 * is a single call. See the handler for the stamping flow, the async/callout
 * reason and the duplicate-stamp suppression flag.
 */
trigger AgreementTrigger on Agreement__c (after update) {
    AgreementTriggerHandler.afterUpdate(Trigger.new, Trigger.oldMap);
}
