/**
 * TemplateParseException — thrown by parseAndSaveTags when parsing fails.
 *
 * IMPORTANT: This is a plain Exception, NOT an AuraHandledException.
 * AuraHandledException can only be thrown from a context that has an
 * Aura/Lightning request (i.e. directly from an @AuraEnabled method called
 * by the LWC framework). When parseAndSaveTags runs inside @future
 * (parseAndSaveTagsAsync), there is no Aura context, and throwing
 * AuraHandledException causes a confusing LimitException:
 *   "Can only throw this exception type from VisualForce or Aura context"
 *
 * Use this for any error path inside parseAndSaveTags. The @future caller
 * catches it and writes the message to Document_Template__c.Last_Parse_Error__c.
 * The synchronous registerTemplate path (called from LWC) wraps any of these
 * in AuraHandledException at the entry point if it needs to.
 */
public with sharing class TemplateParseException extends Exception {}