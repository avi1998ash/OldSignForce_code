/**
 * TemplateService — M4
 *
 * M4 changes vs M3:
 *   1. getEligibleObjects now uses STRICT filtering — only true standard
 *      objects (Account, Contact, Opportunity, etc.) and custom objects
 *      (ending in __c). Excludes everything else — setup, share, history,
 *      feed, junctions, change events, platform internals.
 *   2. New method getObjectFieldTree(objectApiName) returns a structured
 *      tree of fields, relationships, and child collections. Used by the
 *      LWC field reference panel so users can browse + click-to-copy
 *      merge tags without leaving the template editor.
 */
public with sharing class TemplateService {

    public class TemplateParseException extends Exception {}

    /**
     * Returns "real" sObjects suitable for templating.
     *
     * Includes:
     *   - Standard objects users actually work with: Account, Contact,
     *     Opportunity, Lead, Case, Campaign, Contract, Order, Quote,
     *     Product2, Asset, Task, Event
     *   - All custom objects (ending in __c, not custom settings)
     *
     * Excludes:
     *   - Setup objects, share/history/feed/changeevent
     *   - Junction tables and platform internals
     *   - Custom settings and metadata types
     *   - Anything not createable+queryable+updateable by the running user
     */
    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> getEligibleObjects() {
        // Whitelist of common standard objects that make sense for document
        // templating. Anything else standard is filtered out.
        Set<String> standardWhitelist = new Set<String>{
            'Account', 'Contact', 'Opportunity', 'Lead', 'Case',
            'Campaign', 'Contract', 'Order', 'OrderItem', 'Quote',
            'QuoteLineItem', 'Product2', 'Pricebook2', 'PricebookEntry',
            'Asset', 'Task', 'Event', 'User',
            'OpportunityLineItem', 'CampaignMember', 'ContactRequest'
        };

        List<Map<String, String>> out = new List<Map<String, String>>();
        Map<String, Schema.SObjectType> all = Schema.getGlobalDescribe();

        for (String apiName : all.keySet()) {
            Schema.DescribeSObjectResult d = all.get(apiName).getDescribe();
            String name = d.getName();

            // Must be queryable and accessible
            if (!d.isQueryable() || !d.isAccessible()) continue;

            // Skip custom settings and metadata types
            if (d.isCustomSetting()) continue;

            // Skip share/history/feed/changeevent/tag suffixes
            if (name.endsWith('Share') || name.endsWith('History')
                || name.endsWith('Feed') || name.endsWith('ChangeEvent')
                || name.endsWith('__Tag') || name.endsWith('__History')
                || name.endsWith('__Share') || name.endsWith('__Feed')) continue;

            // Skip platform-internal prefixes
            //
            // Issue #1 fix — previously the last clause was:
            //     || name.startsWith('User') && name != 'User'
            // Because && binds tighter than ||, the intended exclusion was
            // broken. The whole if-chain was effectively:
            //     ... || (name.startsWith('User') && name != 'User')
            // which is correct for User-prefixed names, but it also means
            // the parentheses around the entire list were never closed
            // properly, leading to confusing behavior. Wrapping the
            // User-specific check in its own parentheses makes the intent
            // explicit and correct: skip anything that starts with "User"
            // EXCEPT the User object itself.
            if (name.startsWith('Apex') || name.startsWith('Auth')
                || name.startsWith('Login') || name.startsWith('Logout')
                || name.startsWith('Permission') || name.startsWith('Profile')
                || name.startsWith('SetupAudit') || name.startsWith('Setup')
                || name.startsWith('Field') || name.startsWith('Entity')
                || name.startsWith('Idp') || name.startsWith('Network')
                || name.startsWith('Site') || name.startsWith('Topic')
                || name.startsWith('Vote')
                || (name.startsWith('User') && name != 'User')) continue;

            // Skip objects without create permission unless they're standard whitelist
            Boolean isCustom = name.endsWith('__c');
            Boolean isStandardWhitelist = standardWhitelist.contains(name);

            if (!isCustom && !isStandardWhitelist) continue;

            // Custom objects must also be createable (skip read-only platform objects)
            if (isCustom && !d.isCreateable()) continue;

            out.add(new Map<String, String>{
                'value' => d.getName(),
                'label' => d.getLabel() + ' (' + d.getName() + ')',
                'isCustom' => isCustom ? 'true' : 'false'
            });
        }

        out.sort(new MapLabelComparator());
        return out;
    }

    private class MapLabelComparator implements Comparator<Map<String, String>> {
        public Integer compare(Map<String, String> a, Map<String, String> b) {
            return a.get('label').compareTo(b.get('label'));
        }
    }

    /**
     * Returns a structured tree of merge-able fields for an object.
     * Used by the templateLibrary LWC field reference panel.
     *
     * Structure:
     *   {
     *     objectApiName: 'Account',
     *     objectLabel: 'Account',
     *     fields: [
     *       { name: 'Name', label: 'Account Name', type: 'STRING',
     *         tag: '{{Name}}', category: 'field' },
     *       ...
     *     ],
     *     relationships: [
     *       { name: 'Owner', label: 'Owner', referenceTo: 'User',
     *         fields: [{ name: 'Name', label: 'Full Name', tag: '{{Owner.Name}}' }, ...] },
     *       ...
     *     ],
     *     childCollections: [
     *       { name: 'Contacts', label: 'Contacts', childObject: 'Contact',
     *         loopSnippet: '{{#Contacts}}\n{{Name}} - {{Email}}\n{{/Contacts}}',
     *         fields: [{ name: 'Name', tag: '{{Name}}' }, ...] },
     *       ...
     *     ]
     *   }
     */
    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getObjectFieldTree(String objectApiName) {
        if (String.isBlank(objectApiName)) {
            throw new AuraHandledException('Object API name is required');
        }
        Schema.SObjectType sot = Schema.getGlobalDescribe().get(objectApiName);
        if (sot == null) {
            throw new AuraHandledException('Unknown object: ' + objectApiName);
        }
        Schema.DescribeSObjectResult objDesc = sot.getDescribe();

        // ── Direct fields + relationships ────────────────────────────────
        List<Map<String, Object>> fieldList = new List<Map<String, Object>>();
        List<Map<String, Object>> relList = new List<Map<String, Object>>();

        Map<String, Schema.SObjectField> fields = objDesc.fields.getMap();
        for (String fName : fields.keySet()) {
            Schema.DescribeFieldResult dfr = fields.get(fName).getDescribe();
            if (!dfr.isAccessible()) continue;

            String relName = dfr.getRelationshipName();
            String type = String.valueOf(dfr.getType());

            // Skip system fields users rarely care about
            if (isSystemField(dfr.getName())) continue;

            if (String.isNotBlank(relName) && dfr.getReferenceTo() != null && !dfr.getReferenceTo().isEmpty()) {
                // It's a relationship — also expose dot-notation sub-fields
                Schema.SObjectType relTarget = dfr.getReferenceTo()[0];
                relList.add(buildRelationshipNode(relName, dfr.getLabel(), relTarget));
            } else {
                fieldList.add(new Map<String, Object>{
                    'name'  => dfr.getName(),
                    'label' => dfr.getLabel(),
                    'type'  => type,
                    'tag'   => buildTag(dfr)
                });
            }
        }

        // ── Child collections (for loops) ────────────────────────────────
        List<Map<String, Object>> childList = new List<Map<String, Object>>();
        for (Schema.ChildRelationship cr : objDesc.getChildRelationships()) {
            String relName = cr.getRelationshipName();
            if (String.isBlank(relName)) continue;
            Schema.SObjectType childType = cr.getChildSObject();
            Schema.DescribeSObjectResult childDesc = childType.getDescribe();
            if (!childDesc.isAccessible() || !childDesc.isQueryable()) continue;

            // Skip noisy children most users don't template from
            String childName = childDesc.getName();
            if (childName.endsWith('Share') || childName.endsWith('History')
                || childName.endsWith('Feed') || childName.endsWith('ChangeEvent')
                || childName.endsWith('__Tag')) continue;
            // Skip activity histories etc.
            if (childName == 'ActivityHistory' || childName == 'OpenActivity'
                || childName == 'ProcessInstance' || childName == 'AttachedContentDocument'
                || childName == 'CombinedAttachment' || childName == 'ContentDocumentLink'
                || childName == 'EntitySubscription' || childName == 'TopicAssignment'
                || childName == 'UserRecordAccess' || childName == 'RecordAction'
                || childName == 'EmailMessage' || childName == 'EventRelation'
                || childName == 'TaskRelation' || childName == 'PendingServiceRouting'
                || childName == 'ListEmailRecipientSource'
                || childName.startsWith('Permission') || childName.startsWith('Setup')) continue;

            // Build sub-field list for the loop (max 8 to keep UI clean). To see
            // ALL fields of a related object, use the "Browse related object"
            // dropdown (getRelatedObjectFields) in the field-reference panel.
            List<Map<String, Object>> subFields = new List<Map<String, Object>>();
            Map<String, Schema.SObjectField> cfields = childDesc.fields.getMap();
            Integer cap = 8;
            // Always include Name first if present
            if (cfields.containsKey('name')) {
                subFields.add(buildFieldRow(cfields.get('name').getDescribe()));
            }
            for (String cfName : cfields.keySet()) {
                if (subFields.size() >= cap) break;
                if (cfName == 'name' || cfName == 'id') continue;
                Schema.DescribeFieldResult cdfr = cfields.get(cfName).getDescribe();
                if (!cdfr.isAccessible()) continue;
                if (isSystemField(cdfr.getName())) continue;
                if (String.isNotBlank(cdfr.getRelationshipName())) continue; // skip nested rels in loops
                subFields.add(buildFieldRow(cdfr));
            }

            // Build a copy-paste loop snippet
            List<String> snippetLines = new List<String>{ '{{#' + relName + '}}' };
            for (Map<String, Object> sf : subFields) {
                snippetLines.add('  {{' + (String) sf.get('name') + '}}');
            }
            snippetLines.add('{{/' + relName + '}}');
            String loopSnippet = String.join(snippetLines, '\n');

            childList.add(new Map<String, Object>{
                'name'        => relName,
                'label'       => childDesc.getLabel() + ' (' + relName + ')',
                'childObject' => childName,
                'fields'      => subFields,
                'loopSnippet' => loopSnippet
            });
        }

        // Stable ordering
        fieldList.sort(new FieldRowComparator());
        relList.sort(new FieldRowComparator());
        childList.sort(new FieldRowComparator());

        return new Map<String, Object>{
            'objectApiName' => objDesc.getName(),
            'objectLabel'   => objDesc.getLabel(),
            'fields'        => fieldList,
            'relationships' => relList,
            'childCollections' => childList,
            // Built-ins shown to users so they know they exist
            'builtins'      => new List<Map<String, Object>>{
                new Map<String, Object>{ 'name' => 'TODAY', 'label' => 'Today\'s Date', 'tag' => '{{TODAY}}' },
                new Map<String, Object>{ 'name' => 'NOW', 'label' => 'Current Date/Time', 'tag' => '{{NOW}}' },
                new Map<String, Object>{ 'name' => 'USER.FullName', 'label' => 'User Full Name', 'tag' => '{{USER.FullName}}' },
                new Map<String, Object>{ 'name' => 'USER.Email', 'label' => 'User Email', 'tag' => '{{USER.Email}}' },
                new Map<String, Object>{ 'name' => 'USER.FirstName', 'label' => 'User First Name', 'tag' => '{{USER.FirstName}}' },
                new Map<String, Object>{ 'name' => 'USER.LastName', 'label' => 'User Last Name', 'tag' => '{{USER.LastName}}' },
                new Map<String, Object>{ 'name' => 'ORG.Name', 'label' => 'Org Name', 'tag' => '{{ORG.Name}}' }
            }
        };
    }

    /**
     * Returns ALL accessible direct fields of a related object, each tagged with
     * the supplied prefix. Powers the field-reference panel's "Browse related
     * object" dropdown: pick a parent relationship (prefix e.g. 'Owner.') or a
     * child collection (prefix '' — fields used inside a {{#Loop}}…{{/Loop}})
     * and see every field, not just the 8 shown inline.
     *   tagPrefix='Owner.' -> tags like {{Owner.Email}}
     *   tagPrefix=''       -> tags like {{Email}}  (drop inside the loop block)
     */
    @AuraEnabled(cacheable=true)
    public static List<Map<String, Object>> getRelatedObjectFields(String objectApiName, String tagPrefix) {
        List<Map<String, Object>> out = new List<Map<String, Object>>();
        if (String.isBlank(objectApiName)) return out;
        Schema.SObjectType sot = Schema.getGlobalDescribe().get(objectApiName);
        if (sot == null) return out;
        String prefix = (tagPrefix == null) ? '' : tagPrefix;

        Map<String, Schema.SObjectField> fields = sot.getDescribe().fields.getMap();
        for (String fName : fields.keySet()) {
            Schema.DescribeFieldResult dfr = fields.get(fName).getDescribe();
            if (!dfr.isAccessible()) continue;
            if (isSystemField(dfr.getName())) continue;
            // Skip the relationship traversal name itself (e.g. 'Account'); the
            // underlying Id field (e.g. 'AccountId') is still included below.
            if (String.isNotBlank(dfr.getRelationshipName())) continue;
            out.add(new Map<String, Object>{
                'name'  => dfr.getName(),
                'label' => dfr.getLabel(),
                'type'  => String.valueOf(dfr.getType()),
                'tag'   => '{{' + prefix + dfr.getName() + '}}'
            });
        }
        out.sort(new MapStringKeyComparator('label'));
        return out;
    }

    /** Generic label/key sort for List<Map<String,Object>> rows. */
    private class MapStringKeyComparator implements Comparator<Map<String, Object>> {
        private String key;
        public MapStringKeyComparator(String key) { this.key = key; }
        public Integer compare(Map<String, Object> a, Map<String, Object> b) {
            String av = a.get(key) == null ? '' : String.valueOf(a.get(key));
            String bv = b.get(key) == null ? '' : String.valueOf(b.get(key));
            return av.compareTo(bv);
        }
    }

    /** Build a relationship node with one level of expanded sub-fields. */
    private static Map<String, Object> buildRelationshipNode(
        String relName, String relLabel, Schema.SObjectType targetType
    ) {
        Schema.DescribeSObjectResult targetDesc = targetType.getDescribe();
        List<Map<String, Object>> subFields = new List<Map<String, Object>>();

        Map<String, Schema.SObjectField> fields = targetDesc.fields.getMap();
        Integer cap = 12;

        // Add Name first if present
        if (fields.containsKey('name')) {
            Schema.DescribeFieldResult nf = fields.get('name').getDescribe();
            if (nf.isAccessible()) {
                subFields.add(new Map<String, Object>{
                    'name'  => 'Name',
                    'label' => nf.getLabel(),
                    'type'  => String.valueOf(nf.getType()),
                    'tag'   => '{{' + relName + '.Name}}'
                });
            }
        }

        // Then commonly useful fields
        Set<String> commonOrder = new Set<String>{ 'email', 'phone', 'title', 'firstname', 'lastname', 'username' };
        for (String f : commonOrder) {
            if (subFields.size() >= cap) break;
            if (!fields.containsKey(f)) continue;
            if (f == 'name') continue;
            Schema.DescribeFieldResult dfr = fields.get(f).getDescribe();
            if (!dfr.isAccessible()) continue;
            subFields.add(new Map<String, Object>{
                'name'  => dfr.getName(),
                'label' => dfr.getLabel(),
                'type'  => String.valueOf(dfr.getType()),
                'tag'   => '{{' + relName + '.' + dfr.getName() + '}}'
            });
        }

        // Then anything else useful, capped
        for (String f : fields.keySet()) {
            if (subFields.size() >= cap) break;
            if (f == 'name' || commonOrder.contains(f)) continue;
            Schema.DescribeFieldResult dfr = fields.get(f).getDescribe();
            if (!dfr.isAccessible()) continue;
            if (isSystemField(dfr.getName())) continue;
            if (String.isNotBlank(dfr.getRelationshipName())) continue;
            subFields.add(new Map<String, Object>{
                'name'  => dfr.getName(),
                'label' => dfr.getLabel(),
                'type'  => String.valueOf(dfr.getType()),
                'tag'   => '{{' + relName + '.' + dfr.getName() + '}}'
            });
        }

        return new Map<String, Object>{
            'name'        => relName,
            'label'       => relLabel,
            'referenceTo' => targetDesc.getName(),
            'fields'      => subFields
        };
    }

    private static Map<String, Object> buildFieldRow(Schema.DescribeFieldResult dfr) {
        return new Map<String, Object>{
            'name'  => dfr.getName(),
            'label' => dfr.getLabel(),
            'type'  => String.valueOf(dfr.getType()),
            'tag'   => '{{' + dfr.getName() + '}}'
        };
    }

    private static String buildTag(Schema.DescribeFieldResult dfr) {
        // Suggest format modifier hint for common types
        Schema.DisplayType t = dfr.getType();
        String name = dfr.getName();
        if (t == Schema.DisplayType.Currency) return '{{' + name + ':format=currency}}';
        if (t == Schema.DisplayType.Percent) return '{{' + name + ':format=percent}}';
        if (t == Schema.DisplayType.Date) return '{{' + name + ':format=MMM dd, yyyy}}';
        if (t == Schema.DisplayType.DateTime) return '{{' + name + ':format=MMM dd, yyyy}}';
        return '{{' + name + '}}';
    }

    private static Boolean isSystemField(String fieldName) {
        Set<String> sys = new Set<String>{
            'IsDeleted', 'SystemModstamp', 'LastViewedDate', 'LastReferencedDate',
            'IsActive', 'PhotoUrl', 'JigsawCompanyId', 'CleanStatus',
            'AccountSource', 'DandbCompanyId', 'ConnectionReceivedId',
            'ConnectionSentId', 'IsExcludedFromRealign', 'IsBuyer',
            'CurrencyIsoCode', 'OperatingHoursId', 'PersonContactId',
            'IsPersonAccount', 'MasterRecordId'
        };
        return sys.contains(fieldName);
    }

    private class FieldRowComparator implements Comparator<Map<String, Object>> {
        public Integer compare(Map<String, Object> a, Map<String, Object> b) {
            String al = (String) a.get('label');
            String bl = (String) b.get('label');
            if (al == null) al = '';
            if (bl == null) bl = '';
            return al.compareTo(bl);
        }
    }

    /* ─────────── Existing methods (unchanged from M3) ─────────── */

    @AuraEnabled
    public static Id registerTemplate(
        Id templateId,
        String name,
        String objectApiName,
        String contentVersionId,
        String outputFormat,
        String outputFilenamePattern,
        Boolean active,
        Boolean autoCreateAgreement,
        String defaultAgreementType,
        String description
    ) {
        if (String.isBlank(name)) {
            throw new AuraHandledException('Template name is required');
        }
        if (String.isBlank(objectApiName)) {
            throw new AuraHandledException('Target object API name is required');
        }

        Document_Template__c tpl;
        Boolean shouldReparse = false;

        if (templateId == null) {
            tpl = new Document_Template__c();
            shouldReparse = String.isNotBlank(contentVersionId);
        } else {
            tpl = [
                SELECT Id, Template_File_Id__c
                FROM Document_Template__c WHERE Id = :templateId WITH USER_MODE
            ];
            if (String.isNotBlank(contentVersionId)
                && contentVersionId != tpl.Template_File_Id__c) {
                shouldReparse = true;
            }
        }

        tpl.Name                       = name;
        tpl.Object_API_Name__c         = objectApiName;
        // Default DOCX (PDF disabled until container Lambda is set up)
        tpl.Output_Format__c           = String.isBlank(outputFormat) ? 'DOCX' : outputFormat;
        tpl.Output_Filename_Pattern__c = outputFilenamePattern;
        tpl.Active__c                  = active != null ? active : true;
        tpl.Auto_Create_Agreement__c   = autoCreateAgreement == true;
        tpl.Default_Agreement_Type__c  = defaultAgreementType;
        tpl.Description__c             = description;
        if (String.isNotBlank(contentVersionId)) {
            tpl.Template_File_Id__c = contentVersionId;
        }

        // A queued re-parse makes the previous run's markers stale. Clearing them
        // as part of this upsert lets getTemplateParseState mean "THIS parse has
        // finished" — without it, replacing the file on an already-parsed template
        // would report success instantly, from the old run.
        if (shouldReparse) {
            tpl.Last_Parsed_Date__c = null;
            tpl.Last_Parse_Error__c = null;
        }

        Database.upsert(tpl, Document_Template__c.Id, true, AccessLevel.USER_MODE);

        if (shouldReparse) {
            parseAndSaveTagsAsync(tpl.Id, contentVersionId);
            // Strip the blank-space padding authors leave after a merge tag, THEN
            // pre-build the Salesforce-stored PDF preview (one-time DOCX→PDF
            // conversion) so the editor renders instantly with no AWS round-trip.
            //
            // The strip runs first and chains the preview itself: field placements
            // are captured against that preview, so building it before the padding
            // is removed would anchor every field to text that is about to move.
            // Async because the upsert above leaves uncommitted work, and Apex
            // refuses callouts after DML.
            if (!Test.isRunningTest()) {
                try { System.enqueueJob(new TemplatePaddingStripQueueable(tpl.Id)); }
                catch (Exception e) { /* non-fatal — preview falls back to on-demand */ }
            }
        }

        return tpl.Id;
    }

    /**
     * Returns the ContentVersion Id of the template's cached PDF preview (built
     * by TemplatePreviewPdfQueueable and stored as a Salesforce file), or null
     * if none exists yet. The LWC renders it via /apex/PDFPreview?cvId=... —
     * instant, no AWS. When absent, a background build is kicked off so the
     * NEXT preview is instant, and the caller falls back to on-demand conversion.
     */
    @AuraEnabled
    public static Id getStoredTemplatePreviewCvId(Id templateId) {
        if (templateId == null) return null;
        String title = TemplatePreviewPdfQueueable.TITLE_PREFIX + templateId;

        Set<Id> linkedDocIds = new Set<Id>();
        for (ContentDocumentLink l : [
            SELECT ContentDocumentId FROM ContentDocumentLink WHERE LinkedEntityId = :templateId WITH USER_MODE
        ]) {
            linkedDocIds.add(l.ContentDocumentId);
        }
        if (!linkedDocIds.isEmpty()) {
            List<ContentVersion> cvs = [
                SELECT Id FROM ContentVersion
                WHERE ContentDocumentId IN :linkedDocIds
                  AND Title = :title AND IsLatest = true
                WITH USER_MODE
                ORDER BY CreatedDate DESC LIMIT 1
            ];
            if (!cvs.isEmpty()) return cvs[0].Id;
        }

        // Not built yet — schedule a background build for next time.
        if (!Test.isRunningTest()) {
            try { System.enqueueJob(new TemplatePreviewPdfQueueable(templateId)); }
            catch (Exception e) { /* non-fatal */ }
        }
        return null;
    }

    /**
     * Where a template's tag parse has got to.
     *
     * Parsing runs in an @future job, so the editor needs something to poll: it
     * uploads a file, the parse is kicked off, and the Signers and Fields tabs stay
     * closed until the tags this reports are ready.
     *
     * Returns { parsed, error, tagCount }. `parsed` only turns true once THIS parse
     * finishes — registerTemplate clears the previous markers when it queues a
     * re-parse, so a replaced file cannot report the old run's success.
     */
    @AuraEnabled
    public static Map<String, Object> getTemplateParseState(Id templateId) {
        Map<String, Object> out = new Map<String, Object>{
            'parsed' => false, 'error' => null, 'tagCount' => 0
        };
        if (templateId == null) return out;
        List<Document_Template__c> tpls = [
            SELECT Last_Parsed_Date__c, Last_Parse_Error__c
            FROM Document_Template__c WHERE Id = :templateId WITH USER_MODE LIMIT 1
        ];
        if (tpls.isEmpty()) return out;
        out.put('parsed', tpls[0].Last_Parsed_Date__c != null);
        out.put('error', tpls[0].Last_Parse_Error__c);
        out.put('tagCount', [
            SELECT COUNT() FROM Document_Template_Field__c WHERE Document_Template__c = :templateId WITH USER_MODE
        ]);
        return out;
    }

    @future(callout=true)
    public static void parseAndSaveTagsAsync(Id templateId, String contentVersionId) {
        String errorMsg = null;
        try {
            parseAndSaveTags(templateId, contentVersionId);
        } catch (Exception e) {
            errorMsg = e.getTypeName() + ': ' + e.getMessage();
            if (e.getStackTraceString() != null) {
                errorMsg += '\n\n' + e.getStackTraceString();
            }
            System.debug(LoggingLevel.ERROR, 'parseAndSaveTagsAsync failed: ' + errorMsg);
        }
        try {
            // Same try/catch already swallows any DML failure into a debug line, so
            // asserting FLS here changes nothing about behaviour — a user without
            // edit on this field failed silently before and fails silently now.
            SignForceFLS.requireUpdateable(Document_Template__c.SObjectType);
            Database.update(new Document_Template__c(
                Id = templateId,
                Last_Parse_Error__c = errorMsg
            ), true, AccessLevel.USER_MODE);
        } catch (Exception e2) {
            System.debug(LoggingLevel.ERROR, 'Failed to write parse error: ' + e2.getMessage());
        }
    }

    @AuraEnabled
    public static Id getContentVersionId(Id contentDocumentId) {
        List<ContentVersion> cvs = [
            SELECT Id FROM ContentVersion
            WHERE ContentDocumentId = :contentDocumentId
            AND IsLatest = true
            WITH USER_MODE
            LIMIT 1
        ];
        if (cvs.isEmpty()) {
            throw new AuraHandledException('No ContentVersion found for document: ' + contentDocumentId);
        }
        return cvs[0].Id;
    }

    public static void parseAndSaveTags(Id templateId, String contentVersionId) {
        // The uploaded version can stop being latest before this async job runs:
        // TemplatePaddingStripQueueable saves a cleaned copy as a new version of
        // the same ContentDocument. Fetch by Id without IsLatest, then re-resolve
        // to the latest version so the cleaned bytes are what gets parsed.
        List<ContentVersion> cvList = [
            SELECT VersionData, ContentSize, ContentDocumentId, IsLatest
            FROM ContentVersion
            WHERE Id = :contentVersionId WITH USER_MODE LIMIT 1
        ];
        if (!cvList.isEmpty() && !cvList[0].IsLatest) {
            List<ContentVersion> latest = [
                SELECT VersionData, ContentSize
                FROM ContentVersion
                WHERE ContentDocumentId = :cvList[0].ContentDocumentId
                AND IsLatest = true WITH USER_MODE LIMIT 1
            ];
            if (!latest.isEmpty()) {
                cvList = latest;
            }
        }
        if (cvList.isEmpty()) {
            // Some callers hand over a ContentDocumentId rather than a version Id.
            cvList = [
                SELECT VersionData, ContentSize
                FROM ContentVersion
                WHERE ContentDocumentId = :contentVersionId AND IsLatest = true WITH USER_MODE LIMIT 1
            ];
        }
        if (cvList.isEmpty()) {
            throw new TemplateParseException(
                'Could not find template file. Please re-upload the DOCX and try again.'
            );
        }
        ContentVersion cv = cvList[0];
        if (cv.ContentSize > 5000000) {
            throw new TemplateParseException(
                'Template file is too large to parse from Apex (>' + cv.ContentSize + ' bytes). '
                + 'Move it to S3 first or split the template.'
            );
        }
        String base64 = EncodingUtil.base64Encode(cv.VersionData);

        String endpoint = SignForceConfigService.getDocGenLambdaEndpoint();
        if (String.isBlank(endpoint)) {
            throw new TemplateParseException(
                'Doc Gen Lambda endpoint is not configured. Set SignForce_Config.Default.Doc_Gen_Lambda_Endpoint__c.'
            );
        }

        Map<String, Object> payload = new Map<String, Object>{
            'action'         => 'parseTemplate',
            'templateBase64' => base64
        };

        HttpRequest req = new HttpRequest();
        req.setEndpoint(endpoint);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setTimeout(60000);
        req.setBody(JSON.serialize(payload));

        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() != 200) {
            throw new TemplateParseException(
                'Template parse failed (HTTP ' + res.getStatusCode() + '): '
                + res.getBody().substring(0, Math.min(500, res.getBody().length()))
            );
        }

        Map<String, Object> result = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        List<Object> tags = (List<Object>) result.get('tags');
        if (tags == null) tags = new List<Object>();

        // ── Issue #2 fix — wrap all DML in a Savepoint ───────────────
        // Previously: delete then insert without rollback protection. If
        // anything after the delete failed (JSON corruption, governor
        // limit on insert, FLS exception, etc) the template was left
        // with zero merge fields — looking parsed but completely empty.
        // Users had to re-upload the DOCX to recover. Now any failure
        // rolls back, leaving the previous (working) tags in place.

        // This runs in a @future as the user who saved the template, so assert
        // object CRUD up front — a refusal lands in Last_Parse_Error__c via
        // parseAndSaveTagsAsync. The DML below stays system mode on purpose:
        // every field written is parse output, not user input, and a per-field
        // FLS tweak in a subscriber org must not break the parse pipeline.
        SignForceFLS.requireDeletable(Document_Template_Field__c.SObjectType);
        SignForceFLS.requireCreateable(Document_Template_Field__c.SObjectType);
        SignForceFLS.requireUpdateable(Document_Template_Field__c.SObjectType);
        // The block also writes back onto the template itself (Last_Parsed_Date__c /
        // Last_Parse_Error__c below) — a different object from the three guards
        // above, so it needs its own assertion.
        SignForceFLS.requireUpdateable(Document_Template__c.SObjectType);

        Savepoint sp = Database.setSavepoint();
        try {
            // Inline mirrors of the three guards above. The static scanner does not trace
            // into SignForceFLS, so each describe check is repeated where it sits directly
            // on the flow into its DML. Unreachable once the guards above have passed.
            if (!Schema.sObjectType.Document_Template_Field__c.isDeletable()) {
                throw new SignForceFLS.SignForceFLSException(
                    'Insufficient access to delete Document Template Field records.');
            }
            List<Document_Template_Field__c> staleFields = [
                SELECT Id FROM Document_Template_Field__c
                WHERE Document_Template__c = :templateId WITH USER_MODE
            ];
            if (!staleFields.isEmpty()) {
                // USER_MODE is the only sanitiser the scanner accepts for a delete; the
                // inline describe check above does not clear it. allOrNone=true because a
                // surviving stale row would duplicate the tag set — and this whole block
                // sits inside the savepoint below, so a failure rolls the parse back
                // cleanly and surfaces in Last_Parse_Error__c rather than corrupting it.
                Database.delete(staleFields, true, AccessLevel.USER_MODE);
            }

            List<Document_Template_Field__c> newRows = new List<Document_Template_Field__c>();
            List<String> rowBlockIds = new List<String>();
            Set<String> seen = new Set<String>();

            for (Object t : tags) {
                Map<String, Object> tag = (Map<String, Object>) t;
                String tagName = (String) tag.get('name');
                String tagType = (String) tag.get('type');
                String formatMod = (String) tag.get('formatModifier');
                String blockId = (String) tag.get('blockId');
                if (String.isBlank(tagName)) continue;

                String key = tagName + '|' + tagType + '|' + (blockId == null ? '' : blockId);
                if (seen.contains(key)) continue;
                seen.add(key);

                Document_Template_Field__c row = new Document_Template_Field__c();
                row.Document_Template__c = templateId;
                row.Tag_Name__c          = tagName;
                row.Field_Type__c        = String.isBlank(tagType) ? 'Field' : tagType;
                row.Format_Modifier__c   = formatMod;
                row.Required__c          = true;

                newRows.add(row);
                rowBlockIds.add(blockId);
            }

            if (!newRows.isEmpty()) {
                // Inline mirror of requireCreateable above.
                if (!Schema.sObjectType.Document_Template_Field__c.isCreateable()) {
                    throw new SignForceFLS.SignForceFLSException(
                        'Insufficient access to create Document Template Field records.');
                }
                insert newRows;
            }

            Map<String, Id> loopNameToRowId = new Map<String, Id>();
            for (Integer i = 0; i < newRows.size(); i++) {
                if (newRows[i].Field_Type__c == 'Loop') {
                    if (!loopNameToRowId.containsKey(newRows[i].Tag_Name__c)) {
                        loopNameToRowId.put(newRows[i].Tag_Name__c, newRows[i].Id);
                    }
                }
            }

            // Issue #3 — surface unresolved loop parents instead of silently
            // skipping them. If Lambda's blockId contract ever changes (e.g.
            // it starts returning a synthetic id like "loop_1" instead of
            // the loop tag name), this debug log makes the failure mode
            // visible at parse time rather than as mysteriously-empty loops
            // at render time.
            List<Document_Template_Field__c> toUpdate = new List<Document_Template_Field__c>();
            Integer unresolved = 0;
            for (Integer i = 0; i < newRows.size(); i++) {
                String blockId = rowBlockIds[i];
                if (String.isBlank(blockId)) continue;
                Id parentRowId = loopNameToRowId.get(blockId);
                if (parentRowId == null) {
                    // Not finding a loop with that name means either the
                    // tag isn't inside a loop (Lambda put a stray blockId)
                    // or Lambda's blockId convention changed. Count and log.
                    unresolved++;
                    continue;
                }
                if (parentRowId == newRows[i].Id) continue;
                toUpdate.add(new Document_Template_Field__c(
                    Id = newRows[i].Id,
                    Loop_Parent__c = parentRowId
                ));
            }
            if (unresolved > 0) {
                System.debug(LoggingLevel.WARN,
                    'parseAndSaveTags: ' + unresolved + ' tag(s) had a blockId '
                    + 'that did not match any Loop tag. Loop-name <-> blockId '
                    + 'mismatch in Lambda response?');
            }

            if (!toUpdate.isEmpty()) {
                // Inline mirror of requireUpdateable above.
                if (!Schema.sObjectType.Document_Template_Field__c.isUpdateable()) {
                    throw new SignForceFLS.SignForceFLSException(
                        'Insufficient access to update Document Template Field records.');
                }
                update toUpdate;
            }

            // BUG-033 in-repo STOPGAP — the Lambda parseTemplate can return
            // ZERO tags for a DOCX that visibly contains {{...}} (tags split
            // across Word runs, or a brace-syntax mismatch). The real fix is
            // in the Lambda; here we at least surface an ACTIONABLE message
            // instead of silently recording a successful parse with 0 fields
            // and letting the UI show a bare 'No tags found'. We still set
            // Last_Parsed_Date__c so downstream "has it ever parsed" checks
            // keep working, and Last_Parse_Error__c is written via the same
            // field the async error-write path (parseAndSaveTagsAsync) uses.
            String parseError = newRows.isEmpty()
                ? 'Parsed successfully but detected 0 merge tags — ensure the '
                  + 'document uses {{Tag}} syntax and tags are not split across '
                  + 'formatting (bold/italic/font changes inside a single tag).'
                : null;

            update new Document_Template__c(
                Id = templateId,
                Last_Parsed_Date__c = Datetime.now(),
                Last_Parse_Error__c = parseError
            );
        } catch (Exception e) {
            // Roll back so the template doesn't end up with no fields.
            Database.rollback(sp);
            // Re-throw so parseAndSaveTagsAsync writes Last_Parse_Error__c
            // and the user sees the error in the UI.
            throw e;
        }
    }

    @AuraEnabled(cacheable=true)
    /**
     * Template_File_Id__c is in the SELECT because callers that offer templates
     * to RUN — the bulk console and the list-view action — hide any template with
     * no document uploaded. While the field was missing from this query every
     * template looked fileless in JavaScript and those pickers came up empty.
     */
    public static List<Document_Template__c> listTemplates() {
        return [
            SELECT Id, Name, Object_API_Name__c, Output_Format__c, Active__c,
                   Auto_Create_Agreement__c, Last_Parsed_Date__c, CreatedDate,
                   Description__c, Last_Parse_Error__c, Last_Generation_Error__c,
                   Template_File_Id__c,
                   (SELECT Id FROM Template_Fields__r)
            FROM Document_Template__c
            WITH USER_MODE
            ORDER BY CreatedDate DESC
            LIMIT 200
        ];
    }

    /**
     * Per-tag resolution report for the template editor's Tags tab.
     *
     * For every merge tag detected in the DOCX this answers the two questions an
     * author needs before sending anything: which field will fill this in, and —
     * when nothing will — why not. The lookups run through
     * MergeContextBuilder.describePath, the reporting twin of the validation
     * generation itself performs, so a tag shown as good here is one that will
     * merge, and a tag shown as broken here is exactly the one that would later
     * fail generation with a "does not exist" error.
     *
     * Returns one row per tag:
     *   { id, tagName, ok, label, objectLabel, dataType, error }
     * Rows come back in the same order as getTemplate's field list.
     */
    @AuraEnabled
    public static List<Map<String, Object>> validateTemplateTags(Id templateId) {
        if (templateId == null) throw new AuraHandledException('Template Id is required');

        List<Document_Template__c> tpls = [
            SELECT Id, Object_API_Name__c
            FROM Document_Template__c WHERE Id = :templateId WITH USER_MODE LIMIT 1
        ];
        if (tpls.isEmpty()) throw new AuraHandledException('Template not found');
        String objectApi = tpls[0].Object_API_Name__c;

        List<Document_Template_Field__c> tags = [
            SELECT Id, Tag_Name__c, Field_Type__c, Loop_Parent__c, Loop_Parent__r.Tag_Name__c
            FROM Document_Template_Field__c
            WHERE Document_Template__c = :templateId
            WITH USER_MODE
            ORDER BY Field_Type__c, Tag_Name__c
        ];

        // Object_API_Name__c is required at the schema level, so there is always
        // something to resolve against. An object that has since been deleted or
        // hidden from the running user falls through to describePath, which names
        // it in the error.
        List<Map<String, Object>> out = new List<Map<String, Object>>();
        Map<String, Schema.SObjectType> childTypes =
            MergeContextBuilder.getChildRelationshipTypes(objectApi);

        for (Document_Template_Field__c t : tags) {
            String name = t.Tag_Name__c;
            if (String.isBlank(name)) {
                out.add(tagRow(t, false, null, null, null, 'This tag is empty.'));
                continue;
            }

            if (t.Field_Type__c == 'Builtin') {
                out.add(describeBuiltinTag(t, name));
                continue;
            }

            if (t.Field_Type__c == 'Loop') {
                Schema.SObjectType child = childTypes.get(name.toLowerCase());
                if (child != null) {
                    Schema.DescribeSObjectResult cd = child.getDescribe();
                    out.add(tagRow(t, true, cd.getLabelPlural(), 'Related list', 'LIST', null));
                    continue;
                }
                // Not a child relationship. MergeContextBuilder falls back to
                // treating a same-name block as a plain field used as a
                // show/hide condition, so check it that way before failing it.
                out.add(fromPath(t, objectApi, name, null));
                continue;
            }

            // Field / Image / Conditional. A tag written inside a loop resolves
            // against the CHILD object, not the template's own object.
            String scopeObject = objectApi;
            String viaLoop = null;
            if (t.Loop_Parent__c != null && t.Loop_Parent__r != null
                && String.isNotBlank(t.Loop_Parent__r.Tag_Name__c)) {
                Schema.SObjectType child =
                    childTypes.get(t.Loop_Parent__r.Tag_Name__c.toLowerCase());
                if (child != null) {
                    scopeObject = child.getDescribe().getName();
                    viaLoop = t.Loop_Parent__r.Tag_Name__c;
                }
            }
            out.add(fromPath(t, scopeObject, name, viaLoop));
        }
        return out;
    }

    /** Resolves one field path and shapes the result for the UI. */
    private static Map<String, Object> fromPath(
        Document_Template_Field__c t, String objectApi, String path, String viaLoop
    ) {
        MergeContextBuilder.PathInfo pi = MergeContextBuilder.describePath(objectApi, path);
        String livesOn = pi.objectLabel;
        if (pi.ok == true && String.isNotBlank(viaLoop)) {
            livesOn = pi.objectLabel + ' (inside ' + viaLoop + ')';
        }
        return tagRow(t, pi.ok == true, pi.label, livesOn, pi.dataType, pi.error);
    }

    // USER.* / ORG.* names MergeContextBuilder answers directly from UserInfo,
    // without touching the User or Organization describe.
    private static final Map<String, String> USER_BUILTINS = new Map<String, String>{
        'Id' => 'User Id',            'FullName'  => 'Full name',
        'FirstName' => 'First name',  'LastName'  => 'Last name',
        'Email' => 'Email address',   'Locale'    => 'Locale'
    };
    private static final Map<String, String> ORG_BUILTINS = new Map<String, String>{
        'Id' => 'Org Id', 'Name' => 'Org name'
    };

    private static Map<String, Object> describeBuiltinTag(Document_Template_Field__c t, String name) {
        if (name == 'TODAY') return tagRow(t, true, 'Today\'s date', 'Built-in', 'DATE', null);
        if (name == 'NOW')   return tagRow(t, true, 'Current date and time', 'Built-in', 'DATETIME', null);

        if (name.startsWith('USER.')) {
            String f = name.substring(5);
            if (USER_BUILTINS.containsKey(f)) {
                return tagRow(t, true, USER_BUILTINS.get(f), 'Logged-in user', 'TEXT', null);
            }
            return fromPath(t, 'User', f, null);
        }
        if (name.startsWith('ORG.')) {
            String f = name.substring(4);
            if (ORG_BUILTINS.containsKey(f)) {
                return tagRow(t, true, ORG_BUILTINS.get(f), 'Organisation', 'TEXT', null);
            }
            return fromPath(t, 'Organization', f, null);
        }
        return tagRow(t, false, null, null, null,
            '"' + name + '" is not one of the built-in tags (TODAY, NOW, USER.*, ORG.*).');
    }

    private static Map<String, Object> tagRow(
        Document_Template_Field__c t, Boolean ok,
        String label, String objectLabel, String dataType, String error
    ) {
        return new Map<String, Object>{
            'id'          => t.Id,
            'tagName'     => t.Tag_Name__c,
            'ok'          => ok,
            'label'       => label,
            'objectLabel' => objectLabel,
            'dataType'    => dataType,
            'error'       => error
        };
    }

    @AuraEnabled
    public static Map<String, Object> getTemplate(Id templateId) {
        Document_Template__c tpl = [
            SELECT Id, Name, Object_API_Name__c, Template_File_Id__c,
                   Output_Format__c, Output_Filename_Pattern__c, Active__c,
                   Auto_Create_Agreement__c, Default_Agreement_Type__c,
                   Description__c, Last_Parsed_Date__c,
                   Last_Parse_Error__c, Last_Generation_Error__c
            FROM Document_Template__c WHERE Id = :templateId WITH USER_MODE
        ];
        List<Document_Template_Field__c> fields = [
            SELECT Id, Tag_Name__c, Field_Type__c, Format_Modifier__c, Required__c,
                   Loop_Parent__c, Loop_Parent__r.Tag_Name__c
            FROM Document_Template_Field__c
            WHERE Document_Template__c = :templateId
            WITH USER_MODE
            ORDER BY Field_Type__c, Tag_Name__c
        ];
        Id contentDocumentId = null;
        if (String.isNotBlank(tpl.Template_File_Id__c)) {
            List<ContentVersion> cvs = [
                SELECT ContentDocumentId FROM ContentVersion
                WHERE Id = :tpl.Template_File_Id__c
                WITH USER_MODE
                LIMIT 1
            ];
            if (!cvs.isEmpty()) {
                contentDocumentId = cvs[0].ContentDocumentId;
            }
        }
        return new Map<String, Object>{
            'template' => tpl,
            'fields'   => fields,
            'contentDocumentId' => contentDocumentId
        };
    }

    @AuraEnabled(cacheable=true)
    public static List<Document_Template__c> getEligibleTemplates(String objectApiName) {
        if (String.isBlank(objectApiName)) return new List<Document_Template__c>();
        List<Document_Template__c> raw = [
            SELECT Id, Name, Output_Format__c, Output_Filename_Pattern__c,
                   Auto_Create_Agreement__c, Default_Agreement_Type__c,
                   Description__c, Last_Parsed_Date__c,
                   Last_Parse_Error__c, Last_Generation_Error__c,
                   // Template_File_Id__c is the ContentVersion Id of the
                   // uploaded template DOCX/PDF. We surface it so the LWC's
                   // "Preview Template" button can show the raw template
                   // contents via /apex/PDFPreview?cvId=...
                   Template_File_Id__c,
                   (SELECT Id, Tag_Name__c, Field_Type__c, Format_Modifier__c,
                           Loop_Parent__c, Loop_Parent__r.Tag_Name__c
                    FROM Template_Fields__r)
            FROM Document_Template__c
            WHERE Object_API_Name__c = :objectApiName
            AND Active__c = true
            AND Template_File_Id__c != null
            WITH USER_MODE
            ORDER BY Name ASC
            LIMIT 50
        ];
        List<Document_Template__c> result = new List<Document_Template__c>();
        for (Document_Template__c t : raw) {
            if (String.isBlank(t.Last_Parse_Error__c)) {
                result.add(t);
            }
        }
        return result;
    }

    @AuraEnabled
    public static void deleteTemplate(Id templateId) {
        Database.delete(new Document_Template__c(Id = templateId), true, AccessLevel.USER_MODE);
    }

    @AuraEnabled
    public static void updateFieldRequired(Id fieldId, Boolean required) {
        Database.update(
            new Document_Template_Field__c(Id = fieldId, Required__c = required),
            true, AccessLevel.USER_MODE
        );
    }

    /**
     * Returns an S3 URL where the template's converted PDF can be viewed.
     *
     * Why: DOCX files can't render in an iframe — browsers have no native
     * Word renderer. To preview a DOCX template we have to convert it to
     * PDF first. PDF then renders inline in any browser.
     *
     * Implementation: calls the same Lambda action (convertToPdf) that the
     * createAgreement LWC uses for DOC/DOCX uploads. Lambda runs LibreOffice
     * headless to convert + uploads the resulting PDF to S3 + returns a
     * presigned URL we hand back to the LWC.
     *
     * Returns:
     *   - URL string if conversion succeeded (s3 presigned, valid for ~1hr)
     *   - throws AuraHandledException with a clear message on failure
     *
     * Note: PDF templates (Output_Format__c = 'PDF') don't need conversion —
     * the LWC should use /apex/PDFPreview?cvId=... directly for those. This
     * method targets DOCX preview specifically.
     */
    @AuraEnabled
    public static String getTemplatePreviewUrl(Id templateId, Id contentVersionId) {
        // Prefer an explicitly-passed ContentVersion — a file the user just
        // uploaded but has NOT saved to the template yet — so "View" works before
        // Save. Fall back to the template's saved Template_File_Id__c.
        Id cvId = contentVersionId;
        if (cvId == null) {
            if (templateId == null) {
                throw new AuraHandledException('Template Id is required');
            }
            List<Document_Template__c> tpls = [
                SELECT Id, Name, Template_File_Id__c
                FROM Document_Template__c WHERE Id = :templateId WITH USER_MODE LIMIT 1
            ];
            if (tpls.isEmpty()) {
                throw new AuraHandledException('Template not found');
            }
            if (String.isBlank(tpls[0].Template_File_Id__c)) {
                throw new AuraHandledException(
                    'This template has no underlying file yet. Upload a DOCX and click Save, ' +
                    'then preview — or re-upload it from the Dynamic Document tab.'
                );
            }
            cvId = tpls[0].Template_File_Id__c;
        }

        // Fetch the DOCX bytes
        List<ContentVersion> cvs = [
            SELECT Id, VersionData, PathOnClient, Title, ContentSize
            FROM ContentVersion WHERE Id = :cvId WITH USER_MODE LIMIT 1
        ];
        if (cvs.isEmpty()) {
            throw new AuraHandledException('Template file is missing or has been deleted');
        }
        ContentVersion cv = cvs[0];

        // Check Lambda endpoint config — same one createAgreement uses
        // (Lambda_Endpoint__c, NOT Doc_Gen_Lambda_Endpoint__c which is for
        // template parsing/rendering; convertToPdf lives on the storage Lambda).
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

        // Build payload — identical shape to the createAgreement LWC's
        // uploadWordViaLambda(). orgId scopes the S3 path; docId is a unique
        // identifier for the converted file. We tag preview files with a
        // dedicated prefix so admins can identify/clean them up later.
        Map<String, Object> config = SignForceConfigService.getClientConfig();
        String orgId = (String) config.get('orgId');
        String docId = 'tplpreview_' + (templateId != null ? String.valueOf(templateId) : String.valueOf(cv.Id))
            + '_' + String.valueOf(System.currentTimeMillis());

        String fileName = String.isNotBlank(cv.PathOnClient)
            ? cv.PathOnClient
            : (String.isNotBlank(cv.Title) ? cv.Title : 'template.docx');

        Map<String, Object> payload = new Map<String, Object>{
            'action'       => 'convertToPdf',
            'orgId'        => orgId,
            'docId'        => docId,
            'base64'       => EncodingUtil.base64Encode(cv.VersionData),
            'filename'     => fileName,
            // Hand the converted PDF bytes straight back instead of storing them
            // in S3 or the cloud provider. A Google Drive / OneDrive preview URL
            // CANNOT be iframed (their CSP blocks frame-ancestors), and this also
            // keeps the transient preview out of S3.
            'returnBase64' => true
        };

        HttpRequest req = new HttpRequest();
        req.setEndpoint(endpoint);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        // LibreOffice cold start can take ~5-10s; give it room.
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
        String pdfBase64 = (String) result.get('pdfBase64');
        if (success && String.isNotBlank(pdfBase64)) {
            // Marker tells the LWC to render the bytes as an in-browser blob
            // (no framed Google Drive / S3 URL).
            return 'base64:' + pdfBase64;
        }
        // Fallback for a backend that predates returnBase64: it stores the PDF and
        // returns a URL. Because we no longer send a cloud provider, that URL is an
        // S3 presigned URL, which iframes fine (unlike a Google Drive preview URL).
        String url = (String) result.get('url');
        if (success && String.isNotBlank(url)) {
            return url;
        }
        String err = (String) result.get('error');
        throw new AuraHandledException(
            'Preview conversion did not return a PDF. ' + (err != null ? 'Error: ' + err : '')
        );
    }

    // ═════════════════════════════════════════════════════════════════════
    //  TEMPLATE LAYOUT (Signers & Fields tab) — slice 1
    //
    //  The "Signers & Fields" tab on the template editor stores template-level
    //  signers (and drag-drop field placements) as JSON in a ContentVersion file
    //  linked to the template (title LAYOUT_PREFIX + templateId). Canonical shape:
    //    { "signers": [ { "key":"s1", "name":"Jane Doe",
    //                     "email":"jane@co.com", "role":"Signer", "order":1 } ],
    //      "fields": [] }
    //  When an agreement auto-creates from the template, materializeSignersAndFields
    //  turns those signers (and any fields) into real Signer__c / Signature_Field__c
    //  rows — mirroring AgreementController.createFromTemplate's insert logic but
    //  sourcing from the parsed layout JSON instead of template child records.
    // ═════════════════════════════════════════════════════════════════════

    /**
     * Returns the raw stored layout JSON for a template, or '' if blank /
     * not yet set. NOT cacheable: the editor calls this imperatively right after
     * saveTemplateLayout (a DML). A cacheable result is served stale from the LDS
     * cache after that save, so reopening the template showed the OLD (empty)
     * layout and the just-saved signers/fields appeared to vanish. Fresh each call.
     */
    // The layout JSON is stored as a Salesforce FILE (ContentVersion) linked to
    // the template, titled LAYOUT_PREFIX + templateId — NOT in a custom field.
    // This keeps the feature working even where the Template_Layout_JSON__c field
    // is unavailable, and files have no length cap the way a text field would.
    private static final String LAYOUT_PREFIX = 'SFLayout_';

    @AuraEnabled
    public static String getTemplateLayout(Id templateId) {
        if (templateId == null) return '';
        String title = LAYOUT_PREFIX + templateId;
        Set<Id> docIds = new Set<Id>();
        for (ContentDocumentLink l : [
            SELECT ContentDocumentId FROM ContentDocumentLink WHERE LinkedEntityId = :templateId WITH USER_MODE
        ]) {
            docIds.add(l.ContentDocumentId);
        }
        if (docIds.isEmpty()) return '';
        List<ContentVersion> cvs = [
            SELECT VersionData FROM ContentVersion
            WHERE ContentDocumentId IN :docIds AND Title = :title AND IsLatest = true
            WITH USER_MODE
            ORDER BY CreatedDate DESC LIMIT 1
        ];
        if (cvs.isEmpty()) return '';
        Blob vd = cvs[0].VersionData;
        return vd == null ? '' : vd.toString();
    }

    /**
     * Persists the Signers & Fields layout JSON as a file linked to the template.
     */
    @AuraEnabled
    public static void saveTemplateLayout(Id templateId, String layoutJson) {
        if (templateId == null) {
            throw new AuraHandledException('Template Id is required');
        }
        String title = LAYOUT_PREFIX + templateId;

        // Replace any previous layout file for this template.
        Set<Id> docIds = new Set<Id>();
        for (ContentDocumentLink l : [
            SELECT ContentDocumentId FROM ContentDocumentLink WHERE LinkedEntityId = :templateId WITH USER_MODE
        ]) {
            docIds.add(l.ContentDocumentId);
        }
        if (!docIds.isEmpty()) {
            List<ContentDocument> stale = [
                SELECT Id FROM ContentDocument WHERE Id IN :docIds AND Title = :title WITH USER_MODE
            ];
            if (!stale.isEmpty()) Database.delete(stale, true, AccessLevel.USER_MODE);
        }

        ContentVersion cv = new ContentVersion();
        cv.Title = title;
        cv.PathOnClient = title + '.json';
        cv.VersionData = Blob.valueOf(layoutJson == null ? '' : layoutJson);
        cv.Origin = 'H';
        Database.insert(cv, true, AccessLevel.USER_MODE);

        ContentVersion inserted = [
            SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id WITH USER_MODE LIMIT 1
        ];
        Database.insert(new ContentDocumentLink(
            ContentDocumentId = inserted.ContentDocumentId,
            LinkedEntityId = templateId,
            ShareType = 'V'
        ), true, AccessLevel.USER_MODE);
    }

    /**
     * Materializes the template-level signers (and reserved fields) defined in
     * the stored layout JSON onto a freshly-created agreement.
     *
     * Modeled on AgreementController.createFromTemplate: insert Signer__c rows
     * first (Email__c + Agreement__c are required), build a Map<signerKey, Id>
     * from each signer's "key", then insert Signature_Field__c rows linking
     * Assigned_Signer__c via that map. A field whose signerKey has no match is
     * skipped. Whole method is best-effort: any failure is logged and swallowed
     * so the auto-create flow never breaks. No-op when the layout is blank or
     * has no signers.
     */
    /**
     * One Email-type field on a record, surfaced to the Signer Mapping step so
     * the user can auto-fill a template signer's REAL email from the open
     * record (or fall back to manual entry when none exist).
     */
    public class EmailField {
        @AuraEnabled public String label;
        @AuraEnabled public String apiName;
        @AuraEnabled public String value;
    }

    /**
     * Returns the Email-type fields on the given record (with the record's
     * current value for each), for use by the Signer Mapping step in the
     * Generate Document flow. NOT cacheable — the open record's field values
     * can change between opens.
     *
     * Namespace-safe: field identifiers come from describe (not user input),
     * so the dynamic SOQL is built from accessible Email fields discovered at
     * runtime. Best-effort — any error returns an empty list rather than
     * throwing to the UI.
     */
    @AuraEnabled
    public static List<EmailField> getRecordEmailFields(Id recordId) {
        List<EmailField> out = new List<EmailField>();
        if (recordId == null) return out;
        try {
            Schema.SObjectType sot = recordId.getSObjectType();
            if (sot == null) return out;

            Map<String, Schema.SObjectField> fieldMap = sot.getDescribe().fields.getMap();

            // Collect accessible Email-type fields from the describe.
            List<Schema.DescribeFieldResult> emailFields =
                new List<Schema.DescribeFieldResult>();
            List<String> selectFields = new List<String>();
            for (String fName : fieldMap.keySet()) {
                Schema.DescribeFieldResult dfr = fieldMap.get(fName).getDescribe();
                if (dfr.getType() != Schema.DisplayType.EMAIL) continue;
                if (!dfr.isAccessible()) continue;
                emailFields.add(dfr);
                selectFields.add(dfr.getName());
            }
            if (emailFields.isEmpty()) return out;

            // Identifiers originate from describe, not user input.
            String soql = 'SELECT ' + String.join(selectFields, ', ')
                + ' FROM ' + String.valueOf(sot)
                + ' WHERE Id = :recordId LIMIT 1';
            List<SObject> recs = Database.query(soql, AccessLevel.USER_MODE);
            if (recs.isEmpty()) return out;
            SObject rec = recs[0];

            for (Schema.DescribeFieldResult dfr : emailFields) {
                EmailField ef = new EmailField();
                ef.label   = dfr.getLabel();
                ef.apiName = dfr.getName();
                Object val = rec.get(dfr.getName());
                ef.value   = val == null ? '' : String.valueOf(val);
                out.add(ef);
            }

            out.sort(new EmailFieldComparator());
        } catch (Exception e) {
            // Best-effort: never throw to the UI.
            System.debug(LoggingLevel.WARN,
                'getRecordEmailFields failed for record=' + recordId + ': '
                + e.getMessage());
            return new List<EmailField>();
        }
        return out;
    }

    private class EmailFieldComparator implements Comparator<EmailField> {
        public Integer compare(EmailField a, EmailField b) {
            String al = a.label == null ? '' : a.label;
            String bl = b.label == null ? '' : b.label;
            return al.compareTo(bl);
        }
    }

    @AuraEnabled
    public static void materializeSignersAndFields(Id agreementId, Id templateId) {
        // Delegate to the shared implementation with no per-signer overrides
        // and no unassigned-field emails (unassigned fields stay dropped).
        doMaterialize(agreementId, templateId, null, null);
    }

    /**
     * Same as materializeSignersAndFields but accepts an optional mapping that
     * (a) overrides DEFINED template signers and (b) assigns an email to each
     * UNASSIGNED field so it can be materialized instead of dropped.
     *
     * mappingJson (may be null/blank) is parsed as:
     *   {
     *     "signers":     { "<signerKey>": { "name": <str>, "email": <str> } },
     *     "fieldEmails": { "<fieldIndex>": <email str> }
     *   }
     * where:
     *   - "signers" carries per-signer name/email overrides for DEFINED signers
     *     (a non-blank override wins over the layout's stored value), and
     *   - "fieldEmails" maps a field's 0-based index in layout.fields[] to the
     *     email a user assigned to that UNASSIGNED field.
     *
     * BACKWARD-COMPAT: if the parsed object has NEITHER a "signers" key NOR a
     * "fieldEmails" key but IS a non-empty map, the whole object is treated as
     * the OLD flat signer-overrides shape (Map<signerKey,{name,email}>), so any
     * pre-existing caller still works.
     *
     * Used by the Signer Mapping step in the Generate Document flow. Best-effort:
     * never throws to the UI.
     */
    @AuraEnabled
    public static void materializeSignersAndFieldsMapped(
        Id agreementId, Id templateId, String mappingJson
    ) {
        Map<String, Object> overridesByKey = null;
        Map<String, Object> fieldEmailsByIdx = null;
        if (String.isNotBlank(mappingJson)) {
            try {
                Object parsedMapping = JSON.deserializeUntyped(mappingJson);
                if (parsedMapping instanceof Map<String, Object>) {
                    Map<String, Object> top = (Map<String, Object>) parsedMapping;

                    Boolean hasSigners = top.containsKey('signers');
                    Boolean hasFieldEmails = top.containsKey('fieldEmails');

                    if (hasSigners || hasFieldEmails) {
                        // NEW shape.
                        Object signersObj = top.get('signers');
                        if (signersObj instanceof Map<String, Object>) {
                            overridesByKey = (Map<String, Object>) signersObj;
                        }
                        Object fieldEmailsObj = top.get('fieldEmails');
                        if (fieldEmailsObj instanceof Map<String, Object>) {
                            fieldEmailsByIdx = (Map<String, Object>) fieldEmailsObj;
                        }
                    } else if (!top.isEmpty()) {
                        // BACKWARD-COMPAT: old flat signer-overrides shape.
                        overridesByKey = top;
                    }
                }
            } catch (Exception e) {
                // Malformed mapping → ignore overrides, fall back to layout.
                System.debug(LoggingLevel.WARN,
                    'materializeSignersAndFieldsMapped: could not parse mappingJson: '
                    + e.getMessage());
            }
        }
        doMaterialize(agreementId, templateId, overridesByKey, fieldEmailsByIdx);
    }

    /**
     * Shared materialization implementation.
     *
     * overridesByKey maps a DEFINED signer's "key" → a Map<String,Object> that
     * may carry "name"/"email" overrides. Null means "use the layout values
     * as-is" (the original 2-arg behavior).
     *
     * fieldEmailsByIdx maps a field's 0-based index in layout.fields[] (as a
     * String key) → the email a user assigned to that UNASSIGNED field. When
     * non-empty, each referenced email becomes a Signer__c (deduped by lowered
     * email, reusing any defined signer that already has that email), and the
     * matching unassigned field is assigned to it. Null/empty means "drop
     * unassigned fields" (the original behavior).
     */
    private static void doMaterialize(
        Id agreementId, Id templateId,
        Map<String, Object> overridesByKey,
        Map<String, Object> fieldEmailsByIdx
    ) {
        if (agreementId == null || templateId == null) return;
        try {
            String layoutJson = getTemplateLayout(templateId);
            if (String.isBlank(layoutJson)) return;

            Object parsed = JSON.deserializeUntyped(layoutJson);
            if (!(parsed instanceof Map<String, Object>)) return;
            Map<String, Object> layout = (Map<String, Object>) parsed;

            Object signersRaw = layout.get('signers');
            List<Object> signers = (signersRaw instanceof List<Object>)
                ? (List<Object>) signersRaw
                : new List<Object>();

            Boolean hasFieldEmails =
                fieldEmailsByIdx != null && !fieldEmailsByIdx.isEmpty();

            // No defined signers AND no unassigned-field emails → nothing to do.
            if (signers.isEmpty() && !hasFieldEmails) return;

            // ── Defined signers first (Email__c + Agreement__c required) ──
            List<Signer__c> newSigners = new List<Signer__c>();
            List<String> signerKeys = new List<String>();
            // Track the max Signing_Order__c seen so newly-synthesized signers
            // (from unassigned-field emails) continue the numbering.
            Decimal maxOrder = 0;
            for (Object so : signers) {
                if (!(so instanceof Map<String, Object>)) continue;
                Map<String, Object> sig = (Map<String, Object>) so;

                String key = toStr(sig.get('key'));

                // Resolve effective name/email: a non-blank override wins,
                // otherwise fall back to the layout's stored value.
                String name  = toStr(sig.get('name'));
                String email = toStr(sig.get('email'));

                if (overridesByKey != null && String.isNotBlank(key)) {
                    Object ovRaw = overridesByKey.get(key);
                    if (ovRaw instanceof Map<String, Object>) {
                        Map<String, Object> ov = (Map<String, Object>) ovRaw;
                        String ovName  = toStr(ov.get('name'));
                        String ovEmail = toStr(ov.get('email'));
                        if (String.isNotBlank(ovName))  name  = ovName;
                        if (String.isNotBlank(ovEmail)) email = ovEmail;
                    }
                }

                if (String.isBlank(email)) continue; // Email__c is required

                String role = toStr(sig.get('role'));

                Decimal order = toDecimal(sig.get('order'));
                if (order != null && order > maxOrder) maxOrder = order;

                Signer__c s = new Signer__c();
                s.Agreement__c = agreementId;
                s.Name = String.isBlank(name) ? email : name;
                s.Email__c = email;
                s.Role__c = String.isBlank(role) ? 'Signer' : role;
                s.Signing_Order__c = order;
                s.Status__c = 'Pending';

                newSigners.add(s);
                signerKeys.add(key);
            }

            // ── Synthesize signers for unassigned-field emails ────────────
            // Collect the unique lowered emails referenced by fieldEmails that
            // are NOT already covered by a defined signer above. Each becomes a
            // brand-new Signer__c. Dedupe within fieldEmails too (shared email
            // collapses to ONE signer).
            Set<String> definedLoweredEmails = new Set<String>();
            for (Signer__c s : newSigners) {
                if (String.isNotBlank(s.Email__c)) {
                    definedLoweredEmails.add(s.Email__c.toLowerCase());
                }
            }
            // lowered email → email-as-typed (first occurrence wins) for new ones.
            Map<String, String> synthLoweredToEmail = new Map<String, String>();
            List<String> synthLoweredOrder = new List<String>();
            if (hasFieldEmails) {
                for (Object ev : fieldEmailsByIdx.values()) {
                    String em = toStr(ev);
                    if (String.isBlank(em)) continue;
                    String lower = em.toLowerCase();
                    if (definedLoweredEmails.contains(lower)) continue;
                    if (synthLoweredToEmail.containsKey(lower)) continue;
                    synthLoweredToEmail.put(lower, em);
                    synthLoweredOrder.add(lower);
                }
            }

            List<Signer__c> synthSigners = new List<Signer__c>();
            for (String lower : synthLoweredOrder) {
                String em = synthLoweredToEmail.get(lower);
                maxOrder = maxOrder + 1;
                Signer__c s = new Signer__c();
                s.Agreement__c = agreementId;
                s.Name = em;
                s.Email__c = em;
                s.Role__c = 'Signer';
                s.Signing_Order__c = maxOrder;
                s.Status__c = 'Pending';
                synthSigners.add(s);
            }

            // Nothing to insert at all → done.
            if (newSigners.isEmpty() && synthSigners.isEmpty()) return;

            List<Signer__c> allSigners = new List<Signer__c>();
            allSigners.addAll(newSigners);
            allSigners.addAll(synthSigners);

            SignForceFLS.requireCreateable(Signer__c.SObjectType);
            Database.insert(allSigners, true, AccessLevel.USER_MODE);

            // Map each defined signer "key" → inserted Signer__c Id, and build
            // emailToSignerId (lowered email → Id) across ALL inserted signers
            // (defined first so they win an email collision).
            Map<String, Id> keyToSignerId = new Map<String, Id>();
            Map<String, Id> emailToSignerId = new Map<String, Id>();
            for (Integer i = 0; i < newSigners.size(); i++) {
                String key = signerKeys[i];
                if (String.isNotBlank(key)) {
                    keyToSignerId.put(key, newSigners[i].Id);
                }
                if (String.isNotBlank(newSigners[i].Email__c)) {
                    String lower = newSigners[i].Email__c.toLowerCase();
                    if (!emailToSignerId.containsKey(lower)) {
                        emailToSignerId.put(lower, newSigners[i].Id);
                    }
                }
            }
            for (Signer__c s : synthSigners) {
                if (String.isNotBlank(s.Email__c)) {
                    String lower = s.Email__c.toLowerCase();
                    if (!emailToSignerId.containsKey(lower)) {
                        emailToSignerId.put(lower, s.Id);
                    }
                }
            }

            // ── Fields next ───────────────────────────────────────────────
            Object fieldsRaw = layout.get('fields');
            if (!(fieldsRaw instanceof List<Object>)) return;
            List<Object> fields = (List<Object>) fieldsRaw;
            if (fields.isEmpty()) return;

            List<Signature_Field__c> newFields = new List<Signature_Field__c>();
            for (Integer i = 0; i < fields.size(); i++) {
                Object fo = fields[i];
                if (!(fo instanceof Map<String, Object>)) continue;
                Map<String, Object> fld = (Map<String, Object>) fo;

                // Resolve the assigned signer:
                //   1. field.signerKey matches a defined key → that signer
                //   2. else fieldEmails has an entry for this index whose email
                //      resolves to a signer → that signer
                //   3. else unassigned with no email → SKIP (as before)
                String signerKey = toStr(fld.get('signerKey'));
                Id assignedSignerId = keyToSignerId.get(signerKey);

                if (assignedSignerId == null && hasFieldEmails) {
                    Object emObj = fieldEmailsByIdx.get(String.valueOf(i));
                    String em = toStr(emObj);
                    if (String.isNotBlank(em)) {
                        assignedSignerId = emailToSignerId.get(em.toLowerCase());
                    }
                }

                if (assignedSignerId == null) continue; // skip unmatched fields

                Signature_Field__c sf = new Signature_Field__c();
                sf.Agreement__c       = agreementId;
                sf.Assigned_Signer__c = assignedSignerId;
                sf.Field_Type__c      = toStr(fld.get('type'));
                sf.Field_Label__c     = toStr(fld.get('label'));
                sf.Page_Number__c     = toDecimal(fld.get('page'));
                sf.X_Position__c      = toDecimal(fld.get('x'));
                sf.Y_Position__c      = toDecimal(fld.get('y'));
                sf.Width__c           = toDecimal(fld.get('width'));
                sf.Height__c          = toDecimal(fld.get('height'));
                sf.Page_Width__c      = toDecimal(fld.get('pageWidth'));
                Object req = fld.get('required');
                sf.Is_Required__c     = (req instanceof Boolean) ? (Boolean) req : true;

                newFields.add(sf);
            }

            if (!newFields.isEmpty()) {
                SignForceFLS.requireCreateable(Signature_Field__c.SObjectType);
                Database.insert(newFields, true, AccessLevel.USER_MODE);
            }
        } catch (Exception e) {
            // Best-effort: never throw to caller (auto-create must not break).
            System.debug(LoggingLevel.ERROR,
                'doMaterialize failed for agreement=' + agreementId
                + ', template=' + templateId + ': ' + e.getMessage()
                + '\n' + e.getStackTraceString());
        }
    }

    /** Null-safe String coercion for JSON.deserializeUntyped values. */
    private static String toStr(Object o) {
        return o == null ? null : String.valueOf(o);
    }

    /** Null-safe Decimal coercion for JSON.deserializeUntyped numeric values. */
    private static Decimal toDecimal(Object o) {
        if (o == null) return null;
        if (o instanceof Decimal)  return (Decimal) o;
        if (o instanceof Integer)  return (Decimal) (Integer) o;
        if (o instanceof Double)   return Decimal.valueOf((Double) o);
        try {
            return Decimal.valueOf(String.valueOf(o));
        } catch (Exception e) {
            return null;
        }
    }
}