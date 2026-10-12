/**
 * DocumentHistoryController — M5-3
 *
 * Backend for the "Generated Documents" history component. Handles:
 *   - Listing generation logs for a given source record
 *   - Sending the generated file via email (manual, on-demand)
 *   - Re-generating from a past log entry
 *   - Deleting a log entry + associated file
 *
 * Design notes:
 *   - We use Document_Generation_Log__c as the source of truth for "what
 *     was generated from this record". Each log row links to either a
 *     ContentDocument (when auto-create was off) or — indirectly — an
 *     Agreement__c (when auto-create was on). The LWC infers which by
 *     looking at Output_File_Id__c presence.
 *   - For auto-create flows, the file lives on the Agreement, not the
 *     source record. We resolve the agreement via Source_Record_Id__c +
 *     Source_Template__c lookup at query time. This means the history
 *     view stays accurate even if agreements are renamed, deleted, etc.
 *   - Email sending uses Messaging.SingleEmailMessage with the file as
 *     EmailFileAttachment. We DON'T use saveAsActivity=true by default
 *     so we don't pollute the Activity timeline with internal email logs.
 */
public with sharing class DocumentHistoryController {

    public class HistoryException extends Exception {}

    public class HistoryRow {
        @AuraEnabled public String  logId;
        @AuraEnabled public String  templateId;
        @AuraEnabled public String  templateName;
        @AuraEnabled public String  filename;
        @AuraEnabled public String  status;          // 'Success' | 'Failure' | 'In Progress'
        @AuraEnabled public Datetime createdDate;
        @AuraEnabled public String  createdBy;
        @AuraEnabled public Decimal durationMs;
        @AuraEnabled public String  errorMessage;

        @AuraEnabled public String  contentDocumentId;   // when file is in source Files
        @AuraEnabled public String  contentVersionId;
        @AuraEnabled public String  fileExtension;
        @AuraEnabled public String  agreementId;         // when file is on an Agreement
        @AuraEnabled public String  agreementName;
        @AuraEnabled public Boolean wasAutoCreate;
    }

    @AuraEnabled(cacheable=true)
    public static List<HistoryRow> listGenerationsForRecord(Id recordId, Boolean includeFailed) {
        List<HistoryRow> out = new List<HistoryRow>();
        if (recordId == null) return out;

        String statusFilter = (includeFailed == true)
            ? '\'Success\', \'Failure\''
            : '\'Success\'';

        String soql =
            'SELECT Id, Document_Template__c, Document_Template__r.Name, '
            + 'Status__c, Output_File_Id__c, Output_Filename__c, '
            + 'Duration_Ms__c, Error_Message__c, '
            + 'CreatedDate, CreatedBy.Name '
            + 'FROM Document_Generation_Log__c '
            + 'WHERE Source_Record_Id__c = :recordId '
            + 'AND Status__c IN (' + statusFilter + ') '
            + 'ORDER BY CreatedDate DESC LIMIT 100';

        List<Document_Generation_Log__c> logs;
        try {
            logs = Database.query(soql, AccessLevel.USER_MODE);
        } catch (Exception e) {
            throw new AuraHandledException('Could not load history: ' + e.getMessage());
        }
        if (logs.isEmpty()) return out;

        Set<Id> templateIdsForAgreementLookup = new Set<Id>();
        for (Document_Generation_Log__c log : logs) {
            if (log.Status__c == 'Success' && log.Document_Template__c != null) {
                templateIdsForAgreementLookup.add(log.Document_Template__c);
            }
        }

       
        // Pairing logs with the agreements they produced.
        //
        // Agreements that recorded their source run (Source_Generation_Log__c)
        // are matched to that exact log and nothing else. Agreements from
        // before that field existed fall back to the old template heuristic —
        // but zipped OLDEST-first on both sides, because that is the causal
        // order: generation N produced agreement N. The previous newest-first
        // hand-out put "Open Agreement" on a re-generated row and "Generate
        // Agreement" on the run the agreement actually came from.
        Map<String, SObject> agreementByLogId = new Map<String, SObject>();
        Map<Id, List<SObject>> legacyByTemplate = new Map<Id, List<SObject>>();
        if (!templateIdsForAgreementLookup.isEmpty()) {
            try {
                Boolean hasLogLink = false;
                for (String key : Agreement__c.SObjectType.getDescribe().fields.getMap().keySet()) {
                    if (key == 'source_generation_log__c'
                        || key.endsWith('__source_generation_log__c')) {
                        hasLogLink = true;
                        break;
                    }
                }
                String agSoql =
                    'SELECT Id, Name, Source_Template__c, CreatedDate '
                    + (hasLogLink ? ', Source_Generation_Log__c ' : '')
                    + 'FROM Agreement__c '
                    + 'WHERE Source_Record_Id__c = :recordId '
                    + 'AND Source_Template__c IN :templateIdsForAgreementLookup '
                    + 'AND Is_Template__c = false '
                    + 'ORDER BY CreatedDate ASC';
                List<SObject> ags = Database.query(agSoql, AccessLevel.USER_MODE);
                for (SObject ag : ags) {
                    String linkedLog = hasLogLink
                        ? (String) ag.get('Source_Generation_Log__c') : null;
                    if (String.isNotBlank(linkedLog)) {
                        // A linked agreement pairs with its own run only. If that
                        // run is off this page (older than the 100 shown), the
                        // agreement stays unmatched rather than leaking into the
                        // heuristic pool and stealing someone else's badge.
                        agreementByLogId.put(linkedLog.left(15), ag);
                        continue;
                    }
                    Id tplId = (Id) ag.get('Source_Template__c');
                    if (!legacyByTemplate.containsKey(tplId)) {
                        legacyByTemplate.put(tplId, new List<SObject>());
                    }
                    legacyByTemplate.get(tplId).add(ag);   // ASC preserved
                }
            } catch (Exception e) {
                // Agreement fields may not exist yet — silently skip
                System.debug(LoggingLevel.WARN,
                    'Agreement lookup skipped: ' + e.getMessage());
            }
        }

      
        for (Document_Generation_Log__c log : logs) {
            HistoryRow row = new HistoryRow();
            row.logId        = log.Id;
            row.templateId   = log.Document_Template__c;
            row.templateName = log.Document_Template__r != null
                ? log.Document_Template__r.Name : '(deleted template)';
            row.filename     = log.Output_Filename__c;
            row.status       = log.Status__c;
            row.createdDate  = log.CreatedDate;
            row.createdBy    = log.CreatedBy != null ? (String) log.CreatedBy.get('Name') : '';
            row.durationMs   = log.Duration_Ms__c;
            row.errorMessage = log.Error_Message__c;
           
            row.wasAutoCreate = String.isBlank(log.Output_File_Id__c)
                && log.Status__c == 'Success'
                && log.Document_Template__c != null;

          
            if (String.isNotBlank(log.Output_File_Id__c)) {
                row.contentDocumentId = log.Output_File_Id__c;
            }

          
            // Exact pairing only in this pass; the legacy zip runs after the
            // loop, in chronological order, over whatever is left.
            if (log.Status__c == 'Success') {
                SObject linked = agreementByLogId.get(String.valueOf(log.Id).left(15));
                if (linked != null) {
                    row.agreementId   = (String) String.valueOf(linked.get('Id'));
                    row.agreementName = (String) linked.get('Name');
                }
            }

            out.add(row);
        }

        // Legacy zip: rows still without an agreement meet the agreements that
        // never recorded their source run. Both sides oldest-first, so the
        // pairing follows the order things actually happened in.
        for (Integer i = out.size() - 1; i >= 0; i--) {
            HistoryRow row = out[i];
            Document_Generation_Log__c log = logs[i];
            if (row.agreementId != null) continue;
            if (log.Status__c != 'Success' || log.Document_Template__c == null) continue;
            List<SObject> pool = legacyByTemplate.get(log.Document_Template__c);
            if (pool == null || pool.isEmpty()) continue;
            SObject ag = pool.remove(0);
            row.agreementId   = (String) String.valueOf(ag.get('Id'));
            row.agreementName = (String) ag.get('Name');
        }

       
        Set<Id> cdIds = new Set<Id>();
        for (HistoryRow row : out) {
            if (String.isNotBlank(row.contentDocumentId)) {
                cdIds.add(row.contentDocumentId);
            }
        }
        if (!cdIds.isEmpty()) {
           
            Map<Id, Id> latestCvByCd = new Map<Id, Id>();
            Map<Id, String> extByCd  = new Map<Id, String>();
            for (ContentVersion cv : [
                SELECT Id, ContentDocumentId, FileExtension
                FROM ContentVersion
                WHERE ContentDocumentId IN :cdIds AND IsLatest = true
                WITH USER_MODE
            ]) {
                latestCvByCd.put(cv.ContentDocumentId, cv.Id);
                extByCd.put(cv.ContentDocumentId,
                    cv.FileExtension != null ? cv.FileExtension.toLowerCase() : '');
            }
            for (HistoryRow row : out) {
                if (String.isNotBlank(row.contentDocumentId)) {
                    Id cvId = latestCvByCd.get(row.contentDocumentId);
                    if (cvId != null) row.contentVersionId = String.valueOf(cvId);
                    row.fileExtension = extByCd.get(row.contentDocumentId);
                }
            }
        }

        return out;
    }


    /**
     * The address the "Email this document" dialog opens with.
     *
     * What is deliberately NOT in this chain is Owner.Email. An Account has no
     * Email field of its own, so the owner fallback fired for every Account and
     * pre-filled the To box with the address of the person operating the app.
     * Nobody emails a document to themselves, and if they miss it the document
     * goes to whoever owns the record instead of the party it is for.
     *
     * So the chain only ever offers someone the record actually identifies: its
     * own Email, a person at the Account, or the Contact it points at. When none
     * of those exist it returns null and the dialog shows an empty field — an
     * address the user has to type is strictly safer than a confidently wrong
     * one they have to notice.
     */
    @AuraEnabled(cacheable=true)
    public static String resolveRecipientEmail(Id recordId) {
        if (recordId == null) return null;
        try {
            String objApiName = recordId.getSObjectType().getDescribe().getName();
            Map<String, Schema.SObjectField> fields =
                Schema.getGlobalDescribe().get(objApiName).getDescribe().fields.getMap();

            // Try Email field first
            if (fields.containsKey('email')) {
                List<SObject> rows = Database.query(
                    'SELECT Email FROM ' + objApiName + ' WHERE Id = :recordId LIMIT 1',
                    AccessLevel.USER_MODE
                );
                if (!rows.isEmpty()) {
                    Object v = rows[0].get('Email');
                    if (v != null && String.isNotBlank((String) v)) return (String) v;
                }
            }

            // A named Contact beats a guess. Checked BEFORE the account-contact
            // sweep so that a subscriber who models the answer explicitly - an
            // Account with its own Primary_Contact__c, say - is not overruled by
            // "whichever contact was created most recently".
            String viaLookup = emailFromContactLookup(objApiName, recordId, fields);
            if (String.isNotBlank(viaLookup)) return viaLookup;

            // An Account is an organisation, never a mailbox — the recipient is
            // a person at it.
            if (objApiName == 'Account') {
                String viaAccountContact = emailFromAccountContacts(recordId);
                if (String.isNotBlank(viaAccountContact)) return viaAccountContact;
            }

            // Opportunity keeps its people in OpportunityContactRole rather than a
            // lookup, so none of the steps above can reach them — and Opportunity
            // is one of the commonest things a document gets generated against.
            // Without this the field simply came up empty every time.
            if (objApiName == 'Opportunity') {
                String viaRole = emailFromOpportunityContactRole(recordId);
                if (String.isNotBlank(viaRole)) return viaRole;
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'resolveRecipientEmail failed: ' + e.getMessage());
        }
        return null;
    }

    /**
     * The most relevant Contact's email on an Account.
     *
     * "Most relevant" is whatever the org can tell us. Salesforce has no
     * standard primary-contact flag, so the checkbox orgs commonly add for it is
     * found by describe and simply left out of the ORDER BY when absent; after
     * that the newest contact carrying an address is the best available guess.
     *
     * Its own try/catch, not the caller's: a subscriber who cannot read Contact
     * should fall through to the lookup step rather than abandon the whole
     * resolution.
     */
    /**
     * The contact on an Opportunity, preferring the one marked primary.
     *
     * Guarded by a describe check because OpportunityContactRole can be absent in
     * a subscriber org that has Opportunities disabled, and a hard reference would
     * fail to resolve there.
     */
    private static String emailFromOpportunityContactRole(Id opportunityId) {
        try {
            if (!Schema.getGlobalDescribe().containsKey('OpportunityContactRole')) return null;
            List<OpportunityContactRole> roles = [
                SELECT Contact.Email
                FROM OpportunityContactRole
                WHERE OpportunityId = :opportunityId
                AND Contact.Email != null
                WITH USER_MODE
                ORDER BY IsPrimary DESC, CreatedDate DESC
                LIMIT 1
            ];
            if (!roles.isEmpty() && roles[0].Contact != null) {
                return roles[0].Contact.Email;
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'emailFromOpportunityContactRole skipped: ' + e.getMessage());
        }
        return null;
    }

    private static String emailFromAccountContacts(Id accountId) {
        try {
            String primaryFlag = primaryContactFlagField();
            String orderBy = (primaryFlag == null ? '' : primaryFlag + ' DESC, ')
                + 'CreatedDate DESC';
            List<SObject> rows = Database.query(
                'SELECT Email FROM Contact '
                + 'WHERE AccountId = :accountId AND Email != null '
                + 'ORDER BY ' + orderBy + ' LIMIT 1',
                AccessLevel.USER_MODE
            );
            if (!rows.isEmpty()) {
                Object v = rows[0].get('Email');
                if (v != null && String.isNotBlank((String) v)) return (String) v;
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'Account contact lookup skipped: ' + e.getMessage());
        }
        return null;
    }

    /**
     * A checkbox on Contact meaning "this is the primary one", or null.
     *
     * There is no standard field for this, so we match the names orgs actually
     * use; the trailing form covers the same field arriving from a managed
     * package with its namespace on the front. The type is checked too, because
     * "Primary_Contact__c" on Contact could just as easily be a text field
     * someone types a name into, and ordering by that would be meaningless.
     */
    private static String primaryContactFlagField() {
        Set<String> wanted = new Set<String>{
            'primary__c', 'is_primary__c', 'primary_contact__c', 'is_primary_contact__c'
        };
        Map<String, Schema.SObjectField> contactFields =
            Contact.SObjectType.getDescribe().fields.getMap();
        for (String key : contactFields.keySet()) {
            String lower = key.toLowerCase();
            Boolean nameMatches = false;
            for (String w : wanted) {
                if (lower == w || lower.endsWith('__' + w)) {
                    nameMatches = true;
                    break;
                }
            }
            if (!nameMatches) continue;

            Schema.DescribeFieldResult dfr = contactFields.get(key).getDescribe();
            if (dfr.getType() == Schema.DisplayType.BOOLEAN && dfr.isAccessible()) {
                return dfr.getName();
            }
        }
        return null;
    }

    /**
     * Email of the Contact this record points at.
     *
     * The lookup is discovered by describe rather than by name, because this
     * runs against arbitrary subscriber objects and we cannot know what they
     * called theirs. Where an object has several, one named for a primary
     * contact beats the standard ContactId, which beats the rest; the field
     * names are sorted first so a given object always resolves the same way
     * instead of following describe's arbitrary map order.
     *
     * Polymorphic fields (Task.WhoId, which reaches Contact OR Lead) are skipped
     * — they cannot be traversed as Who.Email, and a Lead behind one is not the
     * contact we were asked for. So are the two standard Contact→Contact fields:
     * ReportsToId means "manager" and MasterRecordId means "merged into", and
     * mailing a document to either is exactly the confident wrongness this
     * method exists to avoid.
     */
    private static String emailFromContactLookup(
        String objApiName, Id recordId, Map<String, Schema.SObjectField> fields
    ) {
        try {
            Set<String> notRecipients = new Set<String>{ 'reportstoid', 'masterrecordid' };

            List<String> fieldNames = new List<String>(fields.keySet());
            fieldNames.sort();

            String bestRelationship;
            Integer bestRank = 99;
            for (String key : fieldNames) {
                Schema.DescribeFieldResult dfr = fields.get(key).getDescribe();
                if (dfr.getType() != Schema.DisplayType.REFERENCE || !dfr.isAccessible()) continue;

                List<Schema.SObjectType> refs = dfr.getReferenceTo();
                if (refs == null || refs.size() != 1 || refs[0] != Contact.SObjectType) continue;

                String rel = dfr.getRelationshipName();
                if (String.isBlank(rel)) continue;

                String lower = dfr.getName().toLowerCase();
                if (notRecipients.contains(lower)) continue;
                Integer rank = lower.contains('primary') ? 0 : (lower == 'contactid' ? 1 : 2);
                if (rank < bestRank) {
                    bestRank = rank;
                    bestRelationship = rel;
                }
            }
            if (bestRelationship == null) return null;

            List<SObject> rows = Database.query(
                'SELECT ' + bestRelationship + '.Email FROM ' + objApiName
                + ' WHERE Id = :recordId LIMIT 1',
                AccessLevel.USER_MODE
            );
            if (rows.isEmpty()) return null;

            SObject contact = rows[0].getSObject(bestRelationship);
            if (contact == null) return null;
            Object v = contact.get('Email');
            if (v != null && String.isNotBlank((String) v)) return (String) v;
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'Contact lookup resolution skipped: ' + e.getMessage());
        }
        return null;
    }

  
    @AuraEnabled
    public static void sendDocumentEmail(
        Id logId, String toAddress, String subject, String body
    ) {
        if (logId == null) throw new AuraHandledException('Log Id is required');
        if (String.isBlank(toAddress)) {
            throw new AuraHandledException('Recipient email is required');
        }
        if (!Pattern.matches('^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}$', toAddress)) {
            throw new AuraHandledException('Recipient email looks invalid: ' + toAddress);
        }

        // Fetch the log + identify the file to attach
        Document_Generation_Log__c log = [
            SELECT Id, Status__c, Output_File_Id__c, Output_Filename__c,
                   Document_Template__c, Source_Record_Id__c
            FROM Document_Generation_Log__c
            WHERE Id = :logId
            WITH USER_MODE
            LIMIT 1
        ];
        if (log.Status__c != 'Success') {
            throw new AuraHandledException(
                'Cannot email a failed generation. Re-generate first.'
            );
        }

        ContentVersion source = String.isNotBlank(log.Output_File_Id__c)
            ? fetchVersionByContentDocId(log.Output_File_Id__c)
            : fetchVersionFromAgreement(log.Source_Record_Id__c, log.Document_Template__c);

        if (source == null || source.VersionData == null) {
            throw new AuraHandledException(
                'Could not find the generated file. It may have been deleted.'
            );
        }

        Blob fileBytes = source.VersionData;

        // The log records the name chosen at generation time, but the file the
        // agreement actually holds is not always that format: the signing flow
        // stores a PDF even when the template's output format is DOCX. Sending
        // PDF bytes under a ".docx" name is exactly what makes Word report
        // "unreadable content", so the extension comes from the stored file.
        String filename = withRealExtension(log.Output_Filename__c, source.FileExtension);

       
        Messaging.EmailFileAttachment attach = new Messaging.EmailFileAttachment();
        attach.setFileName(filename);
        attach.setBody(fileBytes);
        // Without this the attachment goes out as application/octet-stream, and
        // mail clients will not preview an unknown binary — Gmail offers only a
        // download. Naming the real type is what turns the attachment back into
        // something the recipient can open in place.
        attach.setContentType(mimeFor(filename));

        String plain = String.isBlank(body) ? 'Please find the attached document.' : body;

        // Same branded shell every other SignForce email uses, so a document sent
        // from here does not arrive looking like it came from a different product.
        String html =
            BrandingService.getEmailHeader() +
            BrandingService.emailBodyOpen() +
            BrandingService.pill('neutral', 'DOCUMENT ATTACHED') +
            BrandingService.heading('A document for you') +
            messageHtml(plain) +
            // No "attached file" card here on purpose: the mail client already
            // shows the attachment, and repeating the name in the body reads as
            // a download link that isn't one.
            BrandingService.footnote(
                'Sent from ' + BrandingService.brandName() +
                '. If this document was not meant for you, please let the sender know.'
            ) +
            BrandingService.emailBodyClose() +
            BrandingService.getEmailFooter();

        Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
        mail.setToAddresses(new String[] { toAddress });
        mail.setSubject(String.isBlank(subject) ? 'Document: ' + filename : subject);
        mail.setHtmlBody(html);
        // Kept alongside the HTML for clients that refuse to render it.
        mail.setPlainTextBody(plain);
        mail.setFileAttachments(new Messaging.EmailFileAttachment[] { attach });
        mail.setSaveAsActivity(false);
        String owaId = AgreementService.getOwaId();
        if (String.isNotBlank(owaId)) mail.setOrgWideEmailAddressId(owaId);

        // Send it. Nothing is written here — saveAsActivity is false and no
        // targetObjectId is set — and both source objects were already read
        // WITH USER_MODE above, so these scanner guards cannot fail for a user
        // who got this far.
        SignForceFLS.requireAccessible(Document_Generation_Log__c.SObjectType);
        SignForceFLS.requireAccessible(ContentVersion.SObjectType);
        // Positive branch: the scanner reads the check on the flow INTO the
        // operation, not the preceding throws. Always true by here, so the
        // result handling below behaves exactly as before.
        Messaging.SendEmailResult[] results = new List<Messaging.SendEmailResult>();
        if (Schema.sObjectType.Document_Generation_Log__c.isAccessible()
            && Schema.sObjectType.ContentVersion.isAccessible()) {
            results = Messaging.sendEmail(
                new Messaging.SingleEmailMessage[] { mail },
                false  // allOrNothing=false so we get errors back instead of unhandled exceptions
            );
        }
        if (results != null && !results.isEmpty() && !results[0].isSuccess()) {
            String reason = '';
            if (results[0].getErrors() != null && !results[0].getErrors().isEmpty()) {
                reason = results[0].getErrors()[0].getMessage();
            }
            throw new AuraHandledException(
                'Email could not be sent: ' + (String.isBlank(reason) ? 'unknown error' : reason)
            );
        }
    }

  
    /**
     * MIME type for an attachment, from its extension.
     *
     * Only the formats SignForce actually produces or stores are listed; anything
     * else falls back to octet-stream, which downloads cleanly even though it
     * will not preview.
     */
    private static String mimeFor(String filename) {
        String name = String.isBlank(filename) ? '' : filename.toLowerCase();
        Integer dot = name.lastIndexOf('.');
        String ext = dot > -1 ? name.substring(dot + 1) : '';

        Map<String, String> types = new Map<String, String>{
            'pdf'  => 'application/pdf',
            'docx' => 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
            'doc'  => 'application/msword',
            'xlsx' => 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
            'xls'  => 'application/vnd.ms-excel',
            'pptx' => 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
            'txt'  => 'text/plain',
            'csv'  => 'text/csv',
            'png'  => 'image/png',
            'jpg'  => 'image/jpeg',
            'jpeg' => 'image/jpeg'
        };
        String mime = types.get(ext);
        return mime == null ? 'application/octet-stream' : mime;
    }

    /**
     * The sender's own message, escaped, with its line breaks kept.
     *
     * BrandingService.paragraph() escapes correctly but flattens everything into
     * one block, which would run "Thanks," straight into the signature on a
     * single line. This splits on blank lines to make paragraphs and turns the
     * remaining single newlines into <br>, while matching paragraph()'s type
     * exactly so the message does not look pasted into the template.
     *
     * escapeHtml4 runs BEFORE the <br> substitution — the other order would
     * escape the tags we just inserted.
     */
    private static String messageHtml(String raw) {
        if (String.isBlank(raw)) return '';
        String colour = BrandingService.getEmailTokens().get('textSub');
        String normalised = raw.replace('\r\n', '\n').replace('\r', '\n');

        String html = '';
        for (String block : normalised.split('\\n{2,}')) {
            if (String.isBlank(block)) continue;
            String safe = block.trim().escapeHtml4().replace('\n', '<br>');
            html += '<p style="margin:0 0 22px;font-size:15px;line-height:24px;color:'
                 + colour + ';">' + safe + '</p>';
        }
        return html;
    }

    /**
     * Swaps the extension on the log's filename for the one the stored file
     * really has, keeping the readable base name (including any "(2)" the
     * numbering added). Falls back to the log name untouched when the stored
     * file reports no extension.
     */
    private static String withRealExtension(String logName, String actualExt) {
        String base = String.isBlank(logName) ? 'Document' : logName;
        if (String.isBlank(actualExt)) return base;

        Integer dot = base.lastIndexOf('.');
        if (dot > 0) base = base.substring(0, dot);
        return base + '.' + actualExt.toLowerCase();
    }

    private static ContentVersion fetchVersionByContentDocId(Id cdId) {
        List<ContentVersion> cvs = [
            SELECT VersionData, FileExtension FROM ContentVersion
            WHERE ContentDocumentId = :cdId AND IsLatest = true
            WITH USER_MODE
            LIMIT 1
        ];
        return cvs.isEmpty() ? null : cvs[0];
    }

    
    private static ContentVersion fetchVersionFromAgreement(Id sourceRecordId, Id templateId) {
        if (sourceRecordId == null || templateId == null) return null;
        try {
            String soql =
                'SELECT Id FROM Agreement__c '
                + 'WHERE Source_Record_Id__c = :sourceRecordId '
                + 'AND Source_Template__c = :templateId '
                + 'AND Is_Template__c = false '
                + 'ORDER BY CreatedDate DESC LIMIT 1';
            List<SObject> ags = Database.query(soql, AccessLevel.USER_MODE);
            if (ags.isEmpty()) return null;
            Id agreementId = (Id) ags[0].get('Id');

            List<Agreement_Document__c> docs = [
                SELECT Content_Version_ID__c
                FROM Agreement_Document__c
                WHERE Agreement__c = :agreementId
                AND Document_Type__c = 'Original'
                WITH USER_MODE
                ORDER BY CreatedDate DESC LIMIT 1
            ];
            if (docs.isEmpty() || String.isBlank(docs[0].Content_Version_ID__c)) return null;

            return [
                SELECT VersionData, FileExtension FROM ContentVersion
                WHERE Id = :docs[0].Content_Version_ID__c WITH USER_MODE LIMIT 1
            ];
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'fetchVersionFromAgreement failed: ' + e.getMessage());
            return null;
        }
    }

   
    @AuraEnabled
    public static DocumentGenerationService.GenerationResult regenerateFromHistory(Id logId) {
        if (logId == null) throw new AuraHandledException('Log Id is required');

        Document_Generation_Log__c log = [
            SELECT Document_Template__c, Source_Record_Id__c
            FROM Document_Generation_Log__c WHERE Id = :logId WITH USER_MODE LIMIT 1
        ];
        if (log.Document_Template__c == null) {
            throw new AuraHandledException('Original template no longer exists');
        }
        if (String.isBlank(log.Source_Record_Id__c)) {
            throw new AuraHandledException('Original source record is missing from this log');
        }

        return DocumentGenerationService.generate(
            log.Document_Template__c, (Id) log.Source_Record_Id__c
        );
    }

   
    @AuraEnabled
    public static void deleteHistoryEntry(Id logId) {
        if (logId == null) throw new AuraHandledException('Log Id is required');

        Document_Generation_Log__c log = [
            SELECT Id, Output_File_Id__c FROM Document_Generation_Log__c
            WHERE Id = :logId WITH USER_MODE LIMIT 1
        ];
        if (String.isNotBlank(log.Output_File_Id__c)) {
            try {
                List<ContentDocument> docs = [
                    SELECT Id FROM ContentDocument WHERE Id = :log.Output_File_Id__c WITH USER_MODE LIMIT 1
                ];
                if (!docs.isEmpty()) Database.delete(docs, true, AccessLevel.USER_MODE);
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN,
                    'ContentDocument delete skipped: ' + e.getMessage());
            }
        }

        Database.delete(log, true, AccessLevel.USER_MODE);
    }

    /**
     * Deletes a generation-history row AND, when the row created an agreement,
     * that whole agreement with everything under it. The agreement's children
     * (Signer__c, Signature_Field__c, Agreement_Document__c, Agreement_Comment__c,
     * Signing_Event__c) are ALL master-detail to Agreement__c, so deleting the
     * agreement cascades them automatically — we only clean up the files (they
     * are ContentDocuments, not master-detail, so they don't cascade).
     *
     * agreementId is passed from the UI (the exact one shown as "Linked to
     * agreement" on this row) so we never guess when several agreements share a
     * template + record. Pass null to just delete the document + log.
     */
    @AuraEnabled
    public static void deleteGeneratedDocument(Id logId, Id agreementId) {
        if (logId == null) throw new AuraHandledException('Log Id is required');

        // Files to remove — the log's output file plus every file linked to the
        // agreement (and its documents). Collected BEFORE the agreement delete,
        // because deleting the agreement removes the links but not the files.
        Set<Id> contentDocIds = new Set<Id>();

        Document_Generation_Log__c log = [
            SELECT Id, Output_File_Id__c FROM Document_Generation_Log__c
            WHERE Id = :logId WITH USER_MODE LIMIT 1
        ];
        if (String.isNotBlank(log.Output_File_Id__c)) {
            contentDocIds.add((Id) log.Output_File_Id__c);
        }

        if (agreementId != null) {
            // Every entity whose files should go: the agreement itself and its
            // Agreement_Document__c children.
            Set<Id> linkedEntityIds = new Set<Id>{ agreementId };
            for (Agreement_Document__c ad : [
                SELECT Id FROM Agreement_Document__c WHERE Agreement__c = :agreementId WITH USER_MODE
            ]) {
                linkedEntityIds.add(ad.Id);
            }
            for (ContentDocumentLink cdl : [
                SELECT ContentDocumentId FROM ContentDocumentLink
                WHERE LinkedEntityId IN :linkedEntityIds
                WITH USER_MODE
            ]) {
                contentDocIds.add(cdl.ContentDocumentId);
            }

            // Delete the agreement — master-detail cascades signers, fields,
            // documents, comments and signing events with it.
            try {
                Database.delete(
                    [SELECT Id FROM Agreement__c WHERE Id = :agreementId WITH USER_MODE],
                    true, AccessLevel.USER_MODE
                );
            } catch (Exception e) {
                throw new AuraHandledException(
                    'Could not delete the linked agreement: ' + e.getMessage());
            }
        }

        if (!contentDocIds.isEmpty()) {
            try {
                List<ContentDocument> docs = [
                    SELECT Id FROM ContentDocument WHERE Id IN :contentDocIds WITH USER_MODE
                ];
                if (!docs.isEmpty()) Database.delete(docs, true, AccessLevel.USER_MODE);
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN,
                    'ContentDocument cleanup skipped: ' + e.getMessage());
            }
        }

        Database.delete(log, true, AccessLevel.USER_MODE);
    }

    
    /**
     * Apex-facing convenience: no signer mapping, so the template's own signers
     * and fields are materialized unchanged. Deliberately NOT @AuraEnabled —
     * Salesforce forbids overloading an @AuraEnabled method, so the two-argument
     * version below is the single entry point for LWC.
     */
    public static Id createAgreementFromHistory(Id logId) {
        return createAgreementFromHistory(logId, null);
    }

    /**
     * Creates the agreement and materializes the template's signers and fields,
     * applying the STEP-2 mapping the caller collected.
     *
     * mappingJson matches what generateDocument sends:
     *   { "signers": { "<key>": { "name": "...", "email": "..." } },
     *     "fieldEmails": { "<index>": "..." } }
     * Pass null/blank to use the template's own values unchanged.
     */
    @AuraEnabled
    public static Id createAgreementFromHistory(Id logId, String mappingJson) {
        if (logId == null) throw new AuraHandledException('Log Id is required');

        Document_Generation_Log__c log = [
            SELECT Id, Document_Template__c, Source_Record_Id__c,
                   Output_File_Id__c, Output_Filename__c, Status__c
            FROM Document_Generation_Log__c WHERE Id = :logId WITH USER_MODE LIMIT 1
        ];
        if (log.Status__c != 'Success') {
            throw new AuraHandledException('Cannot create agreement from a failed generation');
        }

        Boolean hasFile = String.isNotBlank(log.Output_File_Id__c);
        if (!hasFile) {
            // Validate we can re-render
            if (log.Document_Template__c == null || String.isBlank(log.Source_Record_Id__c)) {
                throw new AuraHandledException(
                    'This log is missing template or source record info — cannot create agreement.'
                );
            }
        }

        String defaultType = 'Other';
        Document_Template__c template;
        if (log.Document_Template__c != null) {
            List<Document_Template__c> tpls = [
                SELECT Id, Name, Default_Agreement_Type__c
                FROM Document_Template__c WHERE Id = :log.Document_Template__c WITH USER_MODE LIMIT 1
            ];
            if (!tpls.isEmpty()) {
                template = tpls[0];
                if (String.isNotBlank(template.Default_Agreement_Type__c)) {
                    defaultType = template.Default_Agreement_Type__c;
                }
            }
        }
        String b64;
        String fileName;
        Decimal fileSize;

        if (hasFile) {
            List<ContentVersion> cvs = [
                SELECT Id, Title, PathOnClient, VersionData, ContentSize, FileExtension
                FROM ContentVersion
                WHERE ContentDocumentId = :log.Output_File_Id__c AND IsLatest = true
                WITH USER_MODE
                LIMIT 1
            ];
            if (cvs.isEmpty()) {
                throw new AuraHandledException('Source file is missing or has been deleted');
            }
            ContentVersion cv = cvs[0];
            b64       = EncodingUtil.base64Encode(cv.VersionData);
            fileName  = String.isNotBlank(log.Output_Filename__c)
                ? log.Output_Filename__c
                : (String.isNotBlank(cv.PathOnClient) ? cv.PathOnClient : cv.Title);
            fileSize  = (Decimal) cv.ContentSize;
        } else {
          
            DocumentGenerationService.GenerationResult genResult;
            try {
                genResult = DocumentGenerationService.generate(
                    log.Document_Template__c, (Id) log.Source_Record_Id__c
                );
            } catch (Exception genErr) {
                throw new AuraHandledException(
                    'Could not re-render the document: ' + genErr.getMessage()
                );
            }
            if (genResult == null || genResult.status != 'Success'
                || String.isBlank(genResult.outputBase64)) {
                String errMsg = genResult != null && String.isNotBlank(genResult.errorMessage)
                    ? genResult.errorMessage : 'Document re-render failed';
                throw new AuraHandledException(errMsg);
            }
            b64       = genResult.outputBase64;
            fileName  = String.isNotBlank(genResult.filename)
                ? genResult.filename
                : (String.isNotBlank(log.Output_Filename__c)
                    ? log.Output_Filename__c : 'Generated.docx');
            fileSize  = genResult.byteSize != null ? genResult.byteSize : 0;
        }

       
        // ── Convert Word → PDF BEFORE any DML (callout-before-DML rule) ──
        // The auto-create flow stores a converted PDF in S3 as the agreement
        // Original; this flow previously stored the raw DOCX, which (a) forced
        // a live LibreOffice conversion on every preview and (b) broke stamping
        // (the stamper would try to parse DOCX bytes as a PDF). Converting up
        // front makes both flows identical. On any conversion failure we fall
        // back to the old raw upload so agreement creation is never blocked.
        String s3DocId = null;
        String s3Url = null;
        Decimal s3Size = null;
        String lowerFn = fileName == null ? '' : fileName.toLowerCase();
        Boolean isWordFile = lowerFn.endsWith('.docx') || lowerFn.endsWith('.doc');
        if (isWordFile) {
            try {
                String lambdaEndpoint = SignForceConfigService.getLambdaEndpoint();
                Map<String, Object> cfg = SignForceConfigService.getClientConfig();
                String orgIdStr = (String) cfg.get('orgId');
                String convDocId = 'genagr_' + logId + '_' + String.valueOf(System.currentTimeMillis());

                HttpRequest convReq = new HttpRequest();
                convReq.setEndpoint(lambdaEndpoint);
                convReq.setMethod('POST');
                convReq.setHeader('Content-Type', 'application/json');
                convReq.setTimeout(120000);
                convReq.setBody(JSON.serialize(new Map<String, Object>{
                    'action'   => 'convertToPdf',
                    'orgId'    => orgIdStr,
                    'docId'    => convDocId,
                    'base64'   => b64,
                    'filename' => fileName
                }));

                HttpResponse convRes = new Http().send(convReq);
                if (convRes.getStatusCode() == 200) {
                    Map<String, Object> convJson =
                        (Map<String, Object>) JSON.deserializeUntyped(convRes.getBody());
                    if (convJson.get('url') != null) {
                        s3DocId = convDocId;
                        s3Url = (String) convJson.get('url');
                        Object sz = convJson.get('size');
                        s3Size = sz != null ? Decimal.valueOf(String.valueOf(sz)) : fileSize;
                        if (lowerFn.endsWith('.docx')) {
                            fileName = fileName.substring(0, fileName.length() - 5) + '.pdf';
                        } else {
                            fileName = fileName.substring(0, fileName.length() - 4) + '.pdf';
                        }
                        System.debug('createAgreementFromHistory: Word converted, s3DocId=' + s3DocId);
                    }
                } else {
                    System.debug(LoggingLevel.WARN,
                        'createAgreementFromHistory: convertToPdf HTTP ' + convRes.getStatusCode()
                        + ' — falling back to raw upload');
                }
            } catch (Exception convErr) {
                // Includes the re-render branch where prior DML blocks callouts —
                // we degrade gracefully to the original behaviour.
                System.debug(LoggingLevel.WARN,
                    'createAgreementFromHistory: conversion skipped (' + convErr.getMessage()
                    + ') — falling back to raw upload');
            }
        }

        String agreementName = fileName;
        Integer dotIdx = agreementName.lastIndexOf('.');
        if (dotIdx > 0) agreementName = agreementName.substring(0, dotIdx);

        // Step 1: Create the Agreement__c (Status=Draft)
        Agreement__c agr = AgreementService.createAgreement(
            agreementName, defaultType, 'Sequential', '', null
        );

       
        try {
            if (template != null && log.Source_Record_Id__c != null) {
                // logId included: it is the fact getHistory uses to put the
                // "Open Agreement" button on the exact run this came from.
                DocumentGenerationService.tagAgreementSource(
                    agr.Id, (Id) log.Source_Record_Id__c, template.Id, logId
                );
            }
        } catch (Exception tagErr) {
            System.debug(LoggingLevel.WARN,
                'tagAgreementSource skipped: ' + tagErr.getMessage());
        }

        
        if (String.isNotBlank(s3DocId)) {
            // Converted PDF lives in S3 — register exactly like the auto-create
            // flow (Tier2 S3-backed Original). Stamping + previews now work the
            // same for both flows.
            AgreementController.createAgreementDocumentS3(
                agr.Id, s3DocId, s3Url, fileName,
                (s3Size != null ? s3Size : fileSize), 'Tier2'
            );
        } else {
            AgreementController.uploadTier1Document(
                agr.Id, fileName, b64, fileSize
            );
        }

        // Materialize the template's signers and field placements onto the new
        // agreement, exactly as the generate-and-auto-create flow does. Without
        // this an agreement raised from the history panel arrived with no
        // recipients and no signature fields, even though its template defined
        // both — the two routes to an agreement behaved differently.
        //
        // Best-effort: a failure here must not lose the agreement or its document.
        if (template != null) {
            try {
                TemplateService.materializeSignersAndFieldsMapped(
                    agr.Id, template.Id, String.isBlank(mappingJson) ? '{}' : mappingJson
                );
            } catch (Exception matErr) {
                System.debug(LoggingLevel.WARN,
                    'materializeSignersAndFieldsMapped skipped: ' + matErr.getMessage());
            }
        }

        return agr.Id;
    }

   
    public class PreviewResult {
        @AuraEnabled public String filename;
        @AuraEnabled public String contentVersionId;
        @AuraEnabled public String contentDocumentId;
        @AuraEnabled public Decimal byteSize;
    }

    /**
     * The file this log's document already lives in, if there is one.
     *
     * Two places to look, in order:
     *   1. the log's own Output_File_Id__c — set by the original generation, and
     *      also stamped by a previous preview render;
     *   2. the Original document of the agreement this log auto-created — that is
     *      where the file goes when the template creates an agreement, which is why
     *      the log itself has none.
     *
     * Returns null only when neither holds a live file, in which case the caller
     * genuinely has to re-render.
     */
    private static PreviewResult findExistingPreviewFile(Document_Generation_Log__c log) {
        // 1. On the log itself.
        if (String.isNotBlank(log.Output_File_Id__c)) {
            try {
                List<ContentVersion> cvs = [
                    SELECT Id, ContentDocumentId, Title, FileExtension, ContentSize
                    FROM ContentVersion
                    WHERE ContentDocumentId = :(Id) log.Output_File_Id__c AND IsLatest = true
                    WITH USER_MODE
                    LIMIT 1
                ];
                if (!cvs.isEmpty()) return toPreviewResult(cvs[0], log.Output_Filename__c);
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN,
                    'Preview reuse (log file) skipped: ' + e.getMessage());
            }
        }

        // 2. On the agreement this log created.
        if (log.Document_Template__c == null || String.isBlank(log.Source_Record_Id__c)) return null;
        try {
            Id sourceRecordId = (Id) log.Source_Record_Id__c;
            Id templateId = log.Document_Template__c;
            List<SObject> ags = Database.query(
                'SELECT Id FROM Agreement__c '
                + 'WHERE Source_Record_Id__c = :sourceRecordId '
                + 'AND Source_Template__c = :templateId '
                + 'AND Is_Template__c = false '
                + 'ORDER BY CreatedDate DESC LIMIT 1',
                AccessLevel.USER_MODE
            );
            if (ags.isEmpty()) return null;

            List<Agreement_Document__c> docs = [
                SELECT Content_Version_ID__c
                FROM Agreement_Document__c
                WHERE Agreement__c = :(Id) ags[0].get('Id')
                AND Document_Type__c = 'Original'
                AND Content_Version_ID__c != null
                WITH USER_MODE
                ORDER BY CreatedDate DESC LIMIT 1
            ];
            if (docs.isEmpty()) return null;

            List<ContentVersion> cvs = [
                SELECT Id, ContentDocumentId, Title, FileExtension, ContentSize
                FROM ContentVersion WHERE Id = :(Id) docs[0].Content_Version_ID__c WITH USER_MODE LIMIT 1
            ];
            if (!cvs.isEmpty()) return toPreviewResult(cvs[0], log.Output_Filename__c);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'Preview reuse (agreement file) skipped: ' + e.getMessage());
        }
        return null;
    }

    /** Shapes an existing ContentVersion as a preview result. */
    private static PreviewResult toPreviewResult(ContentVersion cv, String fallbackName) {
        String name = String.isNotBlank(cv.Title) ? cv.Title : fallbackName;
        // The LWC picks its preview route from the filename's extension, so make
        // sure one is present even when the stored Title had none.
        if (String.isNotBlank(name) && String.isNotBlank(cv.FileExtension)
            && !name.toLowerCase().endsWith('.' + cv.FileExtension.toLowerCase())) {
            name += '.' + cv.FileExtension.toLowerCase();
        }
        PreviewResult pr = new PreviewResult();
        pr.filename          = name;
        pr.contentVersionId  = String.valueOf(cv.Id);
        pr.contentDocumentId = String.valueOf(cv.ContentDocumentId);
        pr.byteSize          = cv.ContentSize;
        return pr;
    }

    @AuraEnabled
    public static PreviewResult regenerateForPreview(Id logId) {
        if (logId == null) throw new AuraHandledException('Log Id is required');

        Document_Generation_Log__c log = [
            SELECT Id, Document_Template__c, Source_Record_Id__c,
                   Output_Filename__c, Status__c, Output_File_Id__c
            FROM Document_Generation_Log__c WHERE Id = :logId WITH USER_MODE LIMIT 1
        ];
        if (log.Status__c != 'Success') {
            throw new AuraHandledException('Cannot preview a failed generation');
        }
        if (log.Document_Template__c == null || String.isBlank(log.Source_Record_Id__c)) {
            throw new AuraHandledException(
                'This log is missing template or source record info — cannot preview.'
            );
        }

        // Reuse a file that already exists before re-rendering anything.
        //
        // Previewing used to render and INSERT a new ContentVersion on every click,
        // linked to the source record — so each "Open File" left another copy of the
        // same document on the record. Auto-create rows made it worse: their file
        // lives on the AGREEMENT, so the log never had one to find and every click
        // re-rendered again.
        //
        // Both cases are just a lookup. Rendering is now the last resort, and it
        // happens at most once because the log is stamped with the file afterwards.
        PreviewResult existing = findExistingPreviewFile(log);
        if (existing != null) return existing;

        DocumentGenerationService.GenerationResult gen;
        try {
            gen = DocumentGenerationService.generate(
                log.Document_Template__c, (Id) log.Source_Record_Id__c
            );
        } catch (Exception genErr) {
            throw new AuraHandledException(
                'Could not re-render the document: ' + genErr.getMessage()
            );
        }
        if (gen == null || gen.status != 'Success' || String.isBlank(gen.outputBase64)) {
            String errMsg = gen != null && String.isNotBlank(gen.errorMessage)
                ? gen.errorMessage : 'Re-render failed';
            throw new AuraHandledException(errMsg);
        }

        String fileName = String.isNotBlank(gen.filename)
            ? gen.filename
            : (String.isNotBlank(log.Output_Filename__c) ? log.Output_Filename__c : 'Generated.docx');

        ContentVersion cv = new ContentVersion();
        cv.Title        = fileName;
        cv.PathOnClient = fileName;
        cv.VersionData  = EncodingUtil.base64Decode(gen.outputBase64);
        cv.Origin       = 'H';
        Database.insert(cv, true, AccessLevel.USER_MODE);

        // Get the auto-created ContentDocumentId
        ContentVersion inserted = [
            SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id WITH USER_MODE LIMIT 1
        ];

        try {
            ContentDocumentLink cdl = new ContentDocumentLink();
            cdl.ContentDocumentId = inserted.ContentDocumentId;
            cdl.LinkedEntityId    = (Id) log.Source_Record_Id__c;
            cdl.ShareType         = 'V';
            cdl.Visibility        = 'AllUsers';
            Database.insert(cdl, true, AccessLevel.USER_MODE);
        } catch (Exception linkErr) {
            System.debug(LoggingLevel.WARN,
                'ContentDocumentLink failed: ' + linkErr.getMessage());
        }
       
        try {
            log.Output_File_Id__c = inserted.ContentDocumentId;
            log.Output_Filename__c = fileName;
            Database.update(log, true, AccessLevel.USER_MODE);
        } catch (Exception logErr) {
            System.debug(LoggingLevel.WARN,
                'Log update failed: ' + logErr.getMessage());
        }

        PreviewResult pr = new PreviewResult();
        pr.filename          = fileName;
        pr.contentVersionId  = (String) String.valueOf(inserted.Id);
        pr.contentDocumentId = (String) String.valueOf(inserted.ContentDocumentId);
        pr.byteSize          = gen.byteSize;
        return pr;
    }
    
    @AuraEnabled
    public static String getPreviewUrlForContentVersion(Id contentVersionId) {
        if (contentVersionId == null) {
            throw new AuraHandledException('contentVersionId is required');
        }

        List<ContentVersion> cvs = [
            SELECT Id, VersionData, PathOnClient, Title, FileExtension, ContentSize
            FROM ContentVersion WHERE Id = :contentVersionId WITH USER_MODE LIMIT 1
        ];
        if (cvs.isEmpty()) {
            throw new AuraHandledException('File not found');
        }
        ContentVersion cv = cvs[0];

        // Lambda endpoint (storage/stamping Lambda — has convertToPdf action)
        String endpoint;
        try {
            endpoint = SignForceConfigService.getLambdaEndpoint();
        } catch (Exception e) {
            throw new AuraHandledException(
                'Lambda endpoint is not configured. Ask your admin to set Lambda_Endpoint__c on SignForce_Config__mdt.'
            );
        }
        if (String.isBlank(endpoint)) {
            throw new AuraHandledException('Lambda endpoint is not configured');
        }

        Map<String, Object> config = SignForceConfigService.getClientConfig();
        String orgId = (String) config.get('orgId');
        // Deterministic key (no timestamp): a ContentVersion is immutable, so its
        // converted PDF never goes stale. This lets repeat previews of the same
        // document reuse the already-converted S3 file instead of re-running the
        // slow LibreOffice conversion every time.
        String docId = 'docpreview_' + contentVersionId;

        // CACHE HIT: if this document was already converted, skip LibreOffice and
        // return the existing presigned URL straight away.
        String cached = existingConvertedUrl(endpoint, orgId, docId);
        if (String.isNotBlank(cached)) {
            return cached;
        }

        String fileName = String.isNotBlank(cv.PathOnClient)
            ? cv.PathOnClient
            : (String.isNotBlank(cv.Title) ? cv.Title : 'document.docx');

        Map<String, Object> payload = new Map<String, Object>{
            'action'   => 'convertToPdf',
            'orgId'    => orgId,
            'docId'    => docId,
            'base64'   => EncodingUtil.base64Encode(cv.VersionData),
            'filename' => fileName
        };

        HttpRequest req = new HttpRequest();
        req.setEndpoint(endpoint);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setTimeout(120000);
        req.setBody(JSON.serialize(payload));

        HttpResponse res;
        try {
            res = new Http().send(req);
        } catch (Exception e) {
            throw new AuraHandledException('Lambda call failed: ' + e.getMessage());
        }

        if (res.getStatusCode() != 200) {
            String body = res.getBody() == null ? '' : res.getBody();
            String snippet = body.substring(0, Math.min(500, body.length()));
            throw new AuraHandledException(
                'Conversion failed (HTTP ' + res.getStatusCode() + '): ' + snippet
            );
        }

        Map<String, Object> result = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        Boolean success = result.get('success') == true;
        String url = (String) result.get('url');
        if (!success || String.isBlank(url)) {
            String err = (String) result.get('error');
            throw new AuraHandledException(
                'Lambda did not return a valid PDF URL. ' + (err != null ? 'Error: ' + err : '')
            );
        }
        return url;
    }

    /**
     * Returns the presigned URL for an already-converted preview PDF if it exists
     * in S3, else null. ContentVersions are immutable so a converted preview never
     * goes stale — this lets repeat previews skip the slow LibreOffice conversion.
     * Any failure returns null so the caller falls back to a fresh conversion.
     */
    private static String existingConvertedUrl(String endpoint, String orgId, String docId) {
        if (Test.isRunningTest()) return null; // exercise the full convert path in tests
        try {
            // 1. Ask the Lambda for a presigned GET URL for this deterministic key.
            HttpRequest urlReq = new HttpRequest();
            urlReq.setEndpoint(endpoint);
            urlReq.setMethod('POST');
            urlReq.setHeader('Content-Type', 'application/json');
            urlReq.setTimeout(30000);
            urlReq.setBody(JSON.serialize(new Map<String, Object>{
                'action' => 'getUrl', 'orgId' => orgId, 'docId' => docId
            }));
            HttpResponse urlRes = new Http().send(urlReq);
            if (urlRes.getStatusCode() != 200) return null;
            String presigned = (String) ((Map<String, Object>)
                JSON.deserializeUntyped(urlRes.getBody())).get('url');
            if (String.isBlank(presigned)) return null;

            // 2. Cheap existence probe — fetch one byte. 200/206 => the file exists.
            HttpRequest probe = new HttpRequest();
            probe.setEndpoint(presigned);
            probe.setMethod('GET');
            probe.setHeader('Range', 'bytes=0-0');
            probe.setTimeout(30000);
            HttpResponse probeRes = new Http().send(probe);
            Integer sc = probeRes.getStatusCode();
            return (sc == 200 || sc == 206) ? presigned : null;
        } catch (Exception e) {
            return null;
        }
    }
}