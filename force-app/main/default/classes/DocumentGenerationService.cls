/**
 * DocumentGenerationService — M5-1
 *
 * M3 changes vs M2 (preserved from working version):
 *   1. Reads Output_Format__c from the template (was hardcoded to DOCX)
 *   2. Sends the BuildResult.images map to Lambda alongside context
 *   3. Saves output with the correct extension and behavior:
 *        DOCX → .docx, MIME = application/vnd.openxmlformats-officedocument.wordprocessingml.document
 *        PDF  → .pdf,  MIME = application/pdf
 *   4. On render failure, writes the error to template's Last_Generation_Error__c
 *      so users can see render-time issues just like parse-time ones.
 *
 * M5-1 additions (Auto-create Agreement orchestration moved to LWC):
 *   1. GenerationResult now includes outputBase64, byteSize,
 *      autoCreateAgreement, defaultAgreementType, existingDraftAgreementId,
 *      existingDraftAgreementName — so the LWC can call
 *      AgreementController.createAgreement + uploadTier1Document directly
 *      without a server-side dependency on AgreementController.
 *   2. When Auto_Create_Agreement__c is true, we SKIP saving the file to
 *      the source record's Files. The LWC will route it to the new
 *      agreement instead. This avoids file duplication.
 *   3. New helper findExistingDraft() looks up a Draft Agreement__c with
 *      matching Source_Record_Id__c + Source_Template__c. Used by the LWC
 *      to soft-warn the user before spawning a duplicate. Wrapped in
 *      try/catch + dynamic SOQL so this code deploys cleanly even before
 *      the new fields are added to Agreement__c.
 *
 * Public signature unchanged: generate(Id templateId, Id recordId).
 */
public with sharing class DocumentGenerationService {

    public class GenerationResult {
        @AuraEnabled public Id contentDocumentId;
        // ContentVersion id of the generated file. We surface it so the LWC's
        // "View File" button can show the file via PDFPreview without an
        // extra round-trip. Null when autoCreateAgreement is true (file lives
        // on the agreement, not the source record).
        @AuraEnabled public Id contentVersionId;
        @AuraEnabled public Id logId;
        @AuraEnabled public Id agreementId;
        @AuraEnabled public String filename;
        @AuraEnabled public String outputFormat;
        @AuraEnabled public String status;
        @AuraEnabled public String errorMessage;

        // ── M5-1 additions ─────────────────────────────────────────────
        @AuraEnabled public String  outputBase64;                // file bytes for LWC → Agreement
        @AuraEnabled public Decimal byteSize;                    // size of decoded output
        @AuraEnabled public Boolean autoCreateAgreement;         // mirror of template flag
        @AuraEnabled public String  defaultAgreementType;        // mirror of template field
        @AuraEnabled public String  existingDraftAgreementId;    // null if none exists
        @AuraEnabled public String  existingDraftAgreementName;  // for soft-warning toast
    }

    @AuraEnabled
    public static GenerationResult generate(Id templateId, Id recordId) {
        Long t0 = System.currentTimeMillis();
        GenerationResult result = new GenerationResult();
        result.status = 'Failure';

        Document_Generation_Log__c log = new Document_Generation_Log__c(
            Document_Template__c = templateId,
            Source_Record_Id__c  = recordId,
            Source_Object_Api_Name__c = recordId != null
                ? recordId.getSObjectType().getDescribe().getName()
                : null,
            Status__c = 'In Progress'
        );

        try {
            // 1. Load template
            Document_Template__c template = loadTemplate(templateId);
            String fmt = String.isBlank(template.Output_Format__c) ? 'DOCX' : template.Output_Format__c.toUpperCase();
            result.outputFormat         = fmt;
            result.autoCreateAgreement  = template.Auto_Create_Agreement__c == true;
            result.defaultAgreementType = template.Default_Agreement_Type__c;

            // 2. Build merge context + pre-fetch images
            MergeContextBuilder.BuildResult br = MergeContextBuilder.build(template, recordId);

            // 3. Render filename, then dedupe so re-generating on the same
            //    record produces "Name (2).docx", "Name (3).docx" instead of a
            //    stack of files that all share one title. Counts earlier
            //    generations as well as files on the record, so auto-create
            //    templates — whose output goes to the Agreement, not here — are
            //    numbered too.
            String filename = renderFilename(template, br.context, fmt);
            filename = dedupeFilename(filename, recordId);
            result.filename = filename;

            // 4. Fetch template DOCX bytes (no DML yet)
            String templateBase64 = fetchTemplateBase64(template.Template_File_Id__c);

            // 5. Lambda — must come BEFORE any DML in this method
            String renderedBase64 = renderMerged(templateBase64, br.context, br.images, fmt);

            // ── Callout done, DML allowed again ────────────────────────

            // M5-1: keep the rendered bytes on the result so the LWC can
            // ship them to AgreementController.uploadTier1Document. Decode
            // once to compute byteSize (the agreement upload uses base64
            // directly, so we don't re-encode).
            result.outputBase64 = renderedBase64;
            try {
                result.byteSize = Decimal.valueOf(EncodingUtil.base64Decode(renderedBase64).size());
            } catch (Exception ignore) {
                result.byteSize = null;
            }

            // 6. Save output as ContentVersion — UNLESS auto-create is on
            //    (in that case the file goes to the new agreement instead,
            //    and saving here would duplicate it on the source record).
            if (!result.autoCreateAgreement) {
                Map<String, Id> ids = saveOutputFileWithIds(renderedBase64, filename, fmt, recordId);
                result.contentDocumentId = ids.get('contentDocumentId');
                result.contentVersionId  = ids.get('contentVersionId');
            }

            // 7. M5-1 — surface existing draft hint for the LWC.
            //    (The LWC handles actual agreement creation.)
            if (result.autoCreateAgreement) {
                Map<String, String> existing = findExistingDraft(recordId, templateId);
                if (existing != null) {
                    result.existingDraftAgreementId   = existing.get('id');
                    result.existingDraftAgreementName = existing.get('name');
                }
            }

            // 8. Clear any previous generation error on the template
            try {
                // Same swallow as the rest of this method's best-effort writes —
                // asserting FLS just gives a missing-permission user the same
                // silent no-op they already got from any other DML failure here.
                SignForceFLS.requireUpdateable(Document_Template__c.SObjectType);
                Database.update(new Document_Template__c(
                    Id = templateId,
                    Last_Generation_Error__c = null
                ), true, AccessLevel.USER_MODE);
            } catch (Exception ignore) {}

            // 9. Log success
            log.Status__c          = 'Success';
            log.Output_File_Id__c  = result.contentDocumentId;   // null when auto-create
            log.Output_Filename__c = filename;
            log.Duration_Ms__c     = System.currentTimeMillis() - t0;
            // User mode, but inside the existing swallow: an under-permissioned
            // user simply loses the log row rather than losing the generated
            // document. That was already this block's contract - the FLS guard
            // below has always thrown in here - so enforcing field level too
            // costs nothing behaviourally.
            try {
                SignForceFLS.requireCreateable(Document_Generation_Log__c.SObjectType);
                Database.insert(log, true, AccessLevel.USER_MODE);
                result.logId = log.Id;
            }
            catch (Exception ignore) { /* swallow */ }

            result.status = 'Success';
            return result;

        } catch (Exception e) {
            String msg = e.getTypeName() + ': ' + e.getMessage();
            if (e.getStackTraceString() != null) {
                msg += '\n\n' + e.getStackTraceString();
            }
            result.errorMessage = msg;
            result.status = 'Failure';

            // Best-effort: log + record error on template
            try {
                log.Status__c        = 'Failure';
                log.Error_Message__c = msg.length() > 32000 ? msg.substring(0, 32000) : msg;
                log.Duration_Ms__c   = System.currentTimeMillis() - t0;
                // Same reasoning as the success path: user mode is safe here
                // because the whole block is best-effort and already swallows.
                // A failed generation that also fails to log stays debuggable
                // through the error returned to the caller.
                SignForceFLS.requireCreateable(Document_Generation_Log__c.SObjectType);
                Database.insert(log, true, AccessLevel.USER_MODE);
                result.logId = log.Id;
            } catch (Exception ignore) {}

            try {
                SignForceFLS.requireUpdateable(Document_Template__c.SObjectType);
                Database.update(new Document_Template__c(
                    Id = templateId,
                    Last_Generation_Error__c = msg.length() > 32000 ? msg.substring(0, 32000) : msg
                ), true, AccessLevel.USER_MODE);
            } catch (Exception ignore) {}

            // Async callers (the bulk-generate Queueable) get the Failure back
            // as a return value. Throwing AuraHandledException there is fatal —
            // the platform kills the job with "Can only throw this exception
            // type from VisualForce or Aura context" and ROLLS BACK the
            // transaction, taking the Failure log written above with it. That
            // is exactly how bulk runs used to die at 0 progress with nothing
            // in the log to say why.
            if (System.isQueueable() || System.isFuture() || System.isBatch() || System.isScheduled()) {
                return result;
            }

            AuraHandledException ah = new AuraHandledException(e.getMessage());
            ah.setMessage(e.getMessage());
            throw ah;
        }
    }

    /**
     * Builds a SAMPLE MERGED preview of the template using a real record's data,
     * saves it as a ContentVersion on the template, and returns its Id — so the
     * Fields editor can place fields on a document that looks like the actual
     * generated agreement (real values, real reflow) instead of the raw
     * {{merge-tag}} preview. This dramatically reduces field-placement drift,
     * because the placement surface matches the generation surface.
     *
     * Preview only: no Document_Generation_Log__c, no Agreement — just bytes.
     * Reuses the exact same merge path (MergeContextBuilder + doc-gen Lambda)
     * generation uses, so the rendered layout matches for this record.
     */
    @AuraEnabled
    public static Id getSampleMergedPreviewCvId(Id templateId, Id sampleRecordId) {
        if (templateId == null || sampleRecordId == null) return null;
        try {
            Document_Template__c template = loadTemplate(templateId);
            String fmt = String.isBlank(template.Output_Format__c)
                ? 'DOCX' : template.Output_Format__c.toUpperCase();

            // Merge with the chosen record — callout FIRST, before any DML.
            MergeContextBuilder.BuildResult br = MergeContextBuilder.build(template, sampleRecordId);
            String templateBase64 = fetchTemplateBase64(template.Template_File_Id__c);
            String mergedBase64 = renderMerged(templateBase64, br.context, br.images, fmt);

            // ── callout done, DML allowed ──
            String title = SAMPLE_PREVIEW_PREFIX + templateId;
            deleteStaleSamplePreview(templateId, title);

            ContentVersion cv = new ContentVersion();
            cv.Title        = title;
            cv.PathOnClient = title + '.' + fmt.toLowerCase();
            cv.VersionData  = EncodingUtil.base64Decode(mergedBase64);
            cv.Origin       = 'H';
            Database.insert(cv, true, AccessLevel.USER_MODE);

            ContentVersion inserted = [
                SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id WITH USER_MODE LIMIT 1
            ];
            ContentDocumentLink cdl = new ContentDocumentLink();
            cdl.ContentDocumentId = inserted.ContentDocumentId;
            cdl.LinkedEntityId    = templateId;
            cdl.ShareType         = 'V';
            Database.insert(cdl, true, AccessLevel.USER_MODE);

            return inserted.Id;
        } catch (Exception e) {
            // Preview is a convenience — never surface a hard error to the editor.
            System.debug(LoggingLevel.WARN,
                'getSampleMergedPreviewCvId failed: ' + e.getMessage());
            throw new AuraHandledException(
                'Could not build the sample preview: ' + e.getMessage());
        }
    }

    /**
     * ANCHOR SUPPORT — returns the flattened {tagPath -> renderedValue} for a
     * record, so the Fields editor can locate each merge tag's VALUE in the
     * generated (merged) PDF and re-place anchored fields on it (zero-drift).
     * Loops/images are skipped — fields anchored to those fall back to absolute.
     */
    @AuraEnabled
    public static Map<String, String> getAnchorValues(Id templateId, Id recordId) {
        Map<String, String> out = new Map<String, String>();
        if (templateId == null || recordId == null) return out;
        try {
            Document_Template__c template = loadTemplate(templateId);
            MergeContextBuilder.BuildResult br = MergeContextBuilder.build(template, recordId);
            flattenContext('', br.context, out);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'getAnchorValues failed: ' + e.getMessage());
        }
        return out;
    }

    private static void flattenContext(String prefix, Map<String, Object> ctx, Map<String, String> out) {
        if (ctx == null) return;
        for (String k : ctx.keySet()) {
            Object v = ctx.get(k);
            String key = String.isBlank(prefix) ? k : prefix + '.' + k;
            if (v instanceof Map<String, Object>) {
                flattenContext(key, (Map<String, Object>) v, out);
            } else if (v instanceof List<Object>) {
                // loop content — skip
            } else if (v != null) {
                String s = String.valueOf(v);
                if (String.isNotBlank(s)) out.put(key, s);
            }
        }
    }

    /**
     * ANCHOR SUPPORT (robust) — render the template merged with the record but
     * with a short unique MARKER token prepended to each anchored tag's value.
     * The browser then finds each marker's position on the merged PDF (a marker
     * is always on the value's FIRST line, so long/wrapping/empty values that
     * broke value-matching still resolve). Only unformatted tags are marked;
     * formatted ones ({{x:format=..}}) fall back to absolute.
     *
     * Returns { cvId: <marker preview>, markers: { token -> tagPath } }.
     */
    @AuraEnabled
    public static Map<String, Object> getMarkerMergedPreview(Id templateId, Id recordId) {
        Map<String, Object> res = new Map<String, Object>{
            'cvId' => null, 'markers' => new Map<String, String>()
        };
        if (templateId == null || recordId == null) return res;
        try {
            Document_Template__c template = loadTemplate(templateId);
            // The marker preview exists ONLY so the browser (pdf.js) can read the
            // merged text positions to resolve anchored fields. pdf.js cannot read
            // DOCX, so ALWAYS render this preview as PDF regardless of the
            // template's final output format — otherwise text extraction returns
            // nothing and every anchored field silently keeps its (drifted)
            // absolute position.
            String fmt = 'PDF';
            MergeContextBuilder.BuildResult br = MergeContextBuilder.build(template, recordId);

            Map<String, String> markers = new Map<String, String>();
            Integer i = 0;
            for (String path : anchorTagPaths(templateId)) {
                String token = 'zZq' + i + 'qZz';
                if (markContextLeaf(br.context, path, token)) {
                    markers.put(token, path);
                    i++;
                }
            }
            if (markers.isEmpty()) return res;   // nothing markable

            String templateBase64 = fetchTemplateBase64(template.Template_File_Id__c);
            String mergedBase64 = renderMerged(templateBase64, br.context, br.images, fmt);

            String title = MARKER_PREVIEW_PREFIX + templateId;
            deleteStaleSamplePreview(templateId, title);
            ContentVersion cv = new ContentVersion();
            cv.Title = title;
            cv.PathOnClient = title + '.' + fmt.toLowerCase();
            cv.VersionData = EncodingUtil.base64Decode(mergedBase64);
            cv.Origin = 'H';
            Database.insert(cv, true, AccessLevel.USER_MODE);
            ContentVersion inserted = [SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id WITH USER_MODE LIMIT 1];
            Database.insert(new ContentDocumentLink(
                ContentDocumentId = inserted.ContentDocumentId, LinkedEntityId = templateId, ShareType = 'V'),
                true, AccessLevel.USER_MODE);

            res.put('cvId', inserted.Id);
            res.put('markers', markers);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'getMarkerMergedPreview failed: ' + e.getMessage());
        }
        return res;
    }

    private static final String MARKER_PREVIEW_PREFIX = 'SFMarkerPreview_';

    /** Unique unformatted anchor-tag paths from the template layout. */
    private static Set<String> anchorTagPaths(Id templateId) {
        Set<String> out = new Set<String>();
        try {
            String layoutJson = TemplateService.getTemplateLayout(templateId);
            if (String.isBlank(layoutJson)) return out;
            Object parsed = JSON.deserializeUntyped(layoutJson);
            if (!(parsed instanceof Map<String, Object>)) return out;
            Object fRaw = ((Map<String, Object>) parsed).get('fields');
            if (!(fRaw instanceof List<Object>)) return out;
            for (Object fo : (List<Object>) fRaw) {
                if (!(fo instanceof Map<String, Object>)) continue;
                Object at = ((Map<String, Object>) fo).get('anchorTag');
                if (at == null) continue;
                String tag = String.valueOf(at);
                if (tag.contains(':')) continue;   // formatted — skip (fallback)
                out.add(tag.trim());
            }
        } catch (Exception e) { /* best-effort */ }
        return out;
    }

    /** Prepend `token` to the string leaf at dot `path` in the context. */
    private static Boolean markContextLeaf(Map<String, Object> ctx, String path, String token) {
        if (ctx == null || String.isBlank(path)) return false;
        List<String> parts = path.split('\\.');
        Map<String, Object> node = ctx;
        for (Integer k = 0; k < parts.size() - 1; k++) {
            Object child = node.get(parts[k]);
            if (!(child instanceof Map<String, Object>)) return false;
            node = (Map<String, Object>) child;
        }
        String leaf = parts[parts.size() - 1];
        Object v = node.get(leaf);
        if (v instanceof List<Object>) return false;   // loop — skip
        String s = v == null ? '' : String.valueOf(v);
        node.put(leaf, token + s);
        return true;
    }

    /** ANCHOR SUPPORT — the just-created fields, so the editor can match each to
     *  its template-layout anchor (by x/y/page/type, which materialize copied
     *  verbatim) and resolve its position on the merged PDF. */
    @AuraEnabled
    public static List<Map<String, Object>> getAgreementFieldsForAnchor(Id agreementId) {
        List<Map<String, Object>> out = new List<Map<String, Object>>();
        if (agreementId == null) return out;
        for (Signature_Field__c f : [
            SELECT Id, X_Position__c, Y_Position__c, Page_Number__c, Field_Type__c
            FROM Signature_Field__c WHERE Agreement__c = :agreementId WITH USER_MODE
        ]) {
            out.add(new Map<String, Object>{
                'id' => f.Id,
                'x' => f.X_Position__c,
                'y' => f.Y_Position__c,
                'page' => f.Page_Number__c,
                'type' => f.Field_Type__c
            });
        }
        return out;
    }

    /**
     * ANCHOR SUPPORT — persist the resolved X/Y/page the Fields editor computed
     * by locating each anchored field's tag value in the merged PDF.
     * positionsJson = [{ "id": "<Signature_Field__c Id>", "x": n, "y": n, "page": n }, ...]
     */
    @AuraEnabled
    public static void saveResolvedFieldPositions(String positionsJson) {
        if (String.isBlank(positionsJson)) return;
        List<Signature_Field__c> updates = new List<Signature_Field__c>();
        try {
            List<Object> rows = (List<Object>) JSON.deserializeUntyped(positionsJson);
            for (Object ro : rows) {
                if (!(ro instanceof Map<String, Object>)) continue;
                Map<String, Object> r = (Map<String, Object>) ro;
                if (r.get('id') == null) continue;
                Signature_Field__c sf = new Signature_Field__c(Id = (Id) String.valueOf(r.get('id')));
                if (r.get('x') != null) sf.X_Position__c = Decimal.valueOf(String.valueOf(r.get('x')));
                if (r.get('y') != null) sf.Y_Position__c = Decimal.valueOf(String.valueOf(r.get('y')));
                if (r.get('page') != null) sf.Page_Number__c = Decimal.valueOf(String.valueOf(r.get('page')));
                updates.add(sf);
            }
            if (!updates.isEmpty()) Database.update(updates, true, AccessLevel.USER_MODE);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'saveResolvedFieldPositions failed: ' + e.getMessage());
        }
    }

    /**
     * ANCHOR SUPPORT — records how the last anchor resolution went.
     *
     * Resolution runs in the browser (pdf.js text positions) and every failure path
     * there is a silent early return, so a field that fails to move looks exactly
     * like one that had nothing to do. Persisting the outcome makes it inspectable
     * without another generate-and-guess cycle.
     */
    @AuraEnabled
    public static void saveAnchorDiag(String diagJson) {
        if (String.isBlank(diagJson)) return;
        try {
            List<ContentDocument> stale = [SELECT Id FROM ContentDocument WHERE Title = 'SFAnchorDiag' WITH USER_MODE];
            // allOrNone=false: a stale diag owned by someone else must not stop
            // this user's diag from being written.
            if (!stale.isEmpty()) Database.delete(stale, false, AccessLevel.USER_MODE);
            Database.insert(new ContentVersion(
                Title        = 'SFAnchorDiag',
                PathOnClient = 'SFAnchorDiag.json',
                VersionData  = Blob.valueOf(diagJson),
                Origin       = 'H'
            ), true, AccessLevel.USER_MODE);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'saveAnchorDiag failed: ' + e.getMessage());
        }
    }

    /**
     * PRE-FILLED FIELDS — seeds interactive signing fields with values already
     * known at generation time, so the signer sees them filled in (and can still
     * edit) instead of an empty box.
     *
     *   Email     → the assigned signer's email
     *   Full Name → the assigned signer's name
     *   Company   → the source record's company (its own name if it is an Account,
     *               else its related Account's name, else a Company field)
     *   Title     → the source record's Title
     *
     * Purely additive and safe: it only ever fills a field whose Field_Value__c is
     * currently BLANK, so an admin-preset value is never overwritten, and it leaves
     * Signature / Initial / Date / Checkbox fields untouched. Best-effort — any
     * failure is swallowed so generation is never affected.
     */
    @AuraEnabled
    public static void prefillAgreementFields(Id agreementId, Id recordId) {
        if (agreementId == null) return;
        try {
            List<Signature_Field__c> flds = [
                SELECT Id, Field_Type__c, Field_Value__c,
                       Assigned_Signer__r.Name, Assigned_Signer__r.Email__c
                FROM Signature_Field__c WHERE Agreement__c = :agreementId WITH USER_MODE
            ];
            if (flds.isEmpty()) return;

            // Record-derived values, fetched once, describe-checked so the query
            // never references a field the object does not have.
            String recTitle = null, recCompany = null;
            if (recordId != null) {
                Map<String, String> rv = fetchRecordPrefillValues(recordId);
                recTitle = rv.get('title');
                recCompany = rv.get('company');
            }

            List<Signature_Field__c> toUpdate = new List<Signature_Field__c>();
            for (Signature_Field__c f : flds) {
                if (String.isNotBlank(f.Field_Value__c)) continue;   // never override
                String v = null;
                String t = f.Field_Type__c;
                if (t == 'Email') {
                    v = (f.Assigned_Signer__r != null) ? f.Assigned_Signer__r.Email__c : null;
                } else if (t == 'Full Name') {
                    v = (f.Assigned_Signer__r != null) ? f.Assigned_Signer__r.Name : null;
                } else if (t == 'Company') {
                    v = recCompany;
                } else if (t == 'Title') {
                    v = recTitle;
                }
                if (String.isNotBlank(v)) {
                    f.Field_Value__c = v;
                    toUpdate.add(f);
                }
            }
            if (!toUpdate.isEmpty()) Database.update(toUpdate, true, AccessLevel.USER_MODE);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'prefillAgreementFields skipped: ' + e.getMessage());
        }
    }

    /** Company + Title for a record of any object, selecting only fields it has. */
    private static Map<String, String> fetchRecordPrefillValues(Id recordId) {
        Map<String, String> out = new Map<String, String>();
        try {
            Schema.SObjectType st = recordId.getSObjectType();
            String objName = st.getDescribe().getName();
            Map<String, Schema.SObjectField> fm = st.getDescribe().fields.getMap();

            List<String> sel = new List<String>{ 'Id' };
            if (fm.containsKey('name')) sel.add('Name');
            if (fm.containsKey('title')) sel.add('Title');
            if (fm.containsKey('company')) sel.add('Company');          // e.g. Lead
            if (fm.containsKey('accountid')) sel.add('Account.Name');   // e.g. Contact, Opportunity

            SObject rec = Database.query(
                'SELECT ' + String.join(sel, ', ') + ' FROM ' + objName + ' WHERE Id = :recordId LIMIT 1',
                AccessLevel.USER_MODE
            );

            if (fm.containsKey('title') && rec.get('Title') != null) {
                out.put('title', String.valueOf(rec.get('Title')));
            }
            // Company: the Account's own name, a related Account's name, or a
            // Company field — whichever the object actually offers.
            String company = null;
            if (objName == 'Account' && rec.get('Name') != null) {
                company = String.valueOf(rec.get('Name'));
            } else if (fm.containsKey('company') && rec.get('Company') != null) {
                company = String.valueOf(rec.get('Company'));
            } else if (fm.containsKey('accountid')) {
                SObject acc = rec.getSObject('Account');
                if (acc != null && acc.get('Name') != null) company = String.valueOf(acc.get('Name'));
            }
            if (String.isNotBlank(company)) out.put('company', company);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'fetchRecordPrefillValues skipped: ' + e.getMessage());
        }
        return out;
    }

    /**
     * Reports which fonts a template asks for and which it actually carries.
     *
     * A .docx stores font NAMES, not font data — the typeface only travels with the
     * file when the author enables Word's "Embed fonts in the file". A font that is
     * only named renders in whatever the converter substitutes, and a substitute's
     * glyph widths differ: text re-wraps, the page count shifts and placed fields no
     * longer line up with the content they were positioned against.
     *
     * Embedded fonts ARE preserved (the converter unpacks them per document), so
     * this exists to surface the ones that are not, before anything is generated —
     * a silent substitution is the failure mode we cannot detect after the fact.
     *
     * Returns { requested, embedded, notEmbedded } as lists of family names.
     */
    @AuraEnabled
    public static Map<String, Object> analyzeTemplateFonts(Id templateId) {
        Map<String, Object> out = new Map<String, Object>{
            'requested'   => new List<Object>(),
            'embedded'    => new List<Object>(),
            'notEmbedded' => new List<Object>()
        };
        if (templateId == null) return out;
        try {
            Document_Template__c t = loadTemplate(templateId);
            if (String.isBlank(t.Template_File_Id__c)) return out;

            String endpoint = SignForceConfigService.getLambdaEndpoint();
            if (String.isBlank(endpoint)) return out;

            HttpRequest req = new HttpRequest();
            req.setEndpoint(endpoint);
            req.setMethod('POST');
            req.setHeader('Content-Type', 'application/json');
            req.setTimeout(60000);
            req.setBody(JSON.serialize(new Map<String, Object>{
                'action' => 'analyzeFonts',
                'base64' => fetchTemplateBase64(t.Template_File_Id__c)
            }));

            HttpResponse res = new Http().send(req);
            if (res.getStatusCode() != 200) return out;

            Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            for (String k : new List<String>{ 'requested', 'embedded', 'notEmbedded' }) {
                if (body.get(k) instanceof List<Object>) out.put(k, body.get(k));
            }
        } catch (Exception e) {
            // Advisory only — never block the editor because the report failed.
            System.debug(LoggingLevel.WARN, 'analyzeTemplateFonts failed: ' + e.getMessage());
        }
        return out;
    }

    /**
     * Removes the underlined blank space authors leave after a {{merge tag}}.
     *
     * Fill-in-form templates reserve room for a long value — "Mr./Ms. {{Name}}____,
     * in capacity of" — but those underlined spaces are literal characters that
     * never shrink. A short value leaves a visible gap; a long value gets the
     * padding on top of it. Reserving room is pointless in a generated document
     * because text reflows to fit, so the padding is dropped.
     *
     * The cleaned file is saved as a NEW VERSION of the same ContentDocument, so
     * the author's original stays in version history and nothing is lost. Runs only
     * when the converter reports it actually changed something.
     */
    @AuraEnabled
    public static Map<String, Object> stripTemplatePadding(Id templateId) {
        Map<String, Object> out = new Map<String, Object>{
            'changed' => false, 'removedChars' => 0, 'paragraphs' => 0
        };
        if (templateId == null) return out;

        Document_Template__c t = loadTemplate(templateId);
        if (String.isBlank(t.Template_File_Id__c)) return out;

        String endpoint = SignForceConfigService.getLambdaEndpoint();
        if (String.isBlank(endpoint)) return out;

        // Callout FIRST — no DML may precede it in this transaction.
        Map<String, Object> body;
        try {
            HttpRequest req = new HttpRequest();
            req.setEndpoint(endpoint);
            req.setMethod('POST');
            req.setHeader('Content-Type', 'application/json');
            req.setTimeout(60000);
            req.setBody(JSON.serialize(new Map<String, Object>{
                'action' => 'stripTagPadding',
                'base64' => fetchTemplateBase64(t.Template_File_Id__c)
            }));
            HttpResponse res = new Http().send(req);
            if (res.getStatusCode() != 200) return out;
            body = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'stripTemplatePadding callout failed: ' + e.getMessage());
            return out;
        }

        if (body.get('changed') != true) return out;   // nothing to clean
        String cleaned = (String) body.get('outputBase64');
        if (String.isBlank(cleaned)) return out;

        try {
            ContentVersion current = [
                SELECT ContentDocumentId, Title, PathOnClient
                FROM ContentVersion WHERE Id = :t.Template_File_Id__c WITH USER_MODE LIMIT 1
            ];

            // Same ContentDocument = a new version, not a new file. The author's
            // original remains retrievable from the file's version history.
            ContentVersion cv = new ContentVersion(
                ContentDocumentId = current.ContentDocumentId,
                Title             = current.Title,
                PathOnClient      = current.PathOnClient,
                VersionData       = EncodingUtil.base64Decode(cleaned),
                ReasonForChange   = 'SignForce: removed blank-space padding after merge tags'
            );
            Database.insert(cv, true, AccessLevel.USER_MODE);

            SignForceFLS.requireUpdateable(Document_Template__c.SObjectType);
            Database.update(new Document_Template__c(Id = templateId, Template_File_Id__c = cv.Id), true, AccessLevel.USER_MODE);

            // The cached preview was rendered from the old bytes, and field
            // placements are captured against it — rebuild it now. `true` = upload
            // chain: the preview job then mirrors the cleaned DOCX to any
            // connected cloud provider.
            System.enqueueJob(new TemplatePreviewPdfQueueable(templateId, true));

            out.put('changed', true);
            out.put('removedChars', body.get('removedChars'));
            out.put('paragraphs', body.get('paragraphs'));
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'stripTemplatePadding save failed: ' + e.getMessage());
        }
        return out;
    }

    private static final String SAMPLE_PREVIEW_PREFIX = 'SFSamplePreview_';

    /** Remove the previous sample preview for this template so they don't pile up. */
    private static void deleteStaleSamplePreview(Id templateId, String title) {
        Set<Id> linkedDocIds = new Set<Id>();
        for (ContentDocumentLink l : [
            SELECT ContentDocumentId FROM ContentDocumentLink WHERE LinkedEntityId = :templateId WITH USER_MODE
        ]) {
            linkedDocIds.add(l.ContentDocumentId);
        }
        if (linkedDocIds.isEmpty()) return;
        List<ContentDocument> stale = [
            SELECT Id FROM ContentDocument WHERE Id IN :linkedDocIds AND Title = :title WITH USER_MODE
        ];
        if (!stale.isEmpty()) { try { Database.delete(stale, false, AccessLevel.USER_MODE); } catch (Exception e) { /* non-fatal */ } }
    }

    /* ───── Helpers ───── */

    private static Document_Template__c loadTemplate(Id templateId) {
        if (templateId == null) {
            throw new GenerationException('Template Id is required');
        }
        List<Document_Template__c> tpls = [
            SELECT Id, Name, Object_API_Name__c, Template_File_Id__c,
                   Output_Format__c, Output_Filename_Pattern__c, Active__c,
                   Auto_Create_Agreement__c, Default_Agreement_Type__c,
                   Description__c,
                   (SELECT Id, Tag_Name__c, Field_Type__c, Format_Modifier__c, Required__c,
                           Loop_Parent__c, Loop_Parent__r.Tag_Name__c
                    FROM Template_Fields__r)
            FROM Document_Template__c
            WHERE Id = :templateId
            WITH USER_MODE
            LIMIT 1
        ];
        if (tpls.isEmpty()) {
            throw new GenerationException('Template not found: ' + templateId);
        }
        Document_Template__c tpl = tpls[0];
        if (tpl.Active__c != true) {
            throw new GenerationException('Template "' + tpl.Name + '" is inactive');
        }
        if (String.isBlank(tpl.Template_File_Id__c)) {
            throw new GenerationException('Template "' + tpl.Name + '" has no file uploaded');
        }
        return tpl;
    }

    private static String fetchTemplateBase64(String fileId) {
        // The stored version id can stop being latest — the padding-strip
        // queueable saves a cleaned copy as a new version of the same document,
        // and a stale editor save can point the template back at the old id —
        // so resolve to the latest version FIRST, then load the bytes once
        // (never two blobs in heap at the same time).
        Id dataId = null;
        List<ContentVersion> byId = [
            SELECT Id, ContentDocumentId, IsLatest FROM ContentVersion
            WHERE Id = :fileId WITH USER_MODE LIMIT 1
        ];
        if (!byId.isEmpty()) {
            dataId = byId[0].Id;
            if (!byId[0].IsLatest) {
                List<ContentVersion> latest = [
                    SELECT Id FROM ContentVersion
                    WHERE ContentDocumentId = :byId[0].ContentDocumentId AND IsLatest = true
                    WITH USER_MODE LIMIT 1
                ];
                if (!latest.isEmpty()) dataId = latest[0].Id;
            }
        } else {
            // Some callers hand over a ContentDocumentId rather than a version Id.
            List<ContentVersion> byDoc = [
                SELECT Id FROM ContentVersion
                WHERE ContentDocumentId = :fileId AND IsLatest = true
                WITH USER_MODE LIMIT 1
            ];
            if (!byDoc.isEmpty()) dataId = byDoc[0].Id;
        }
        if (dataId == null) {
            throw new GenerationException(
                'Template file not found in Salesforce Files. File Id: ' + fileId
            );
        }
        return EncodingUtil.base64Encode([
            SELECT VersionData FROM ContentVersion WHERE Id = :dataId WITH USER_MODE LIMIT 1
        ][0].VersionData);
    }

    private static String callLambdaGenerate(
        String templateBase64,
        Map<String, Object> ctx,
        Map<String, Object> images,
        String outputFormat
    ) {
        String endpoint = SignForceConfigService.getDocGenLambdaEndpoint();
        if (String.isBlank(endpoint)) {
            throw new GenerationException(
                'Doc Gen Lambda endpoint is not configured. Set SignForce_Config.Default.Doc_Gen_Lambda_Endpoint__c.'
            );
        }

        Map<String, Object> payload = new Map<String, Object>{
            'action'         => 'generateFromTemplate',
            'templateBase64' => templateBase64,
            'context'        => ctx,
            'outputFormat'   => outputFormat,
            'images'         => images != null ? images : new Map<String, Object>()
        };

        HttpRequest req = new HttpRequest();
        req.setEndpoint(endpoint);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        // Longer timeout for PDF since LibreOffice cold start can take a few seconds
        req.setTimeout(120000);
        req.setBody(JSON.serialize(payload));

        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() != 200) {
            String body = res.getBody();
            String snippet = body == null ? '' : body.substring(0, Math.min(800, body.length()));
            throw new GenerationException(
                'Lambda generate failed (HTTP ' + res.getStatusCode() + '): ' + snippet
            );
        }

        Map<String, Object> resp = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        String b64 = (String) resp.get('outputBase64');
        if (String.isBlank(b64)) {
            String err = (String) resp.get('error');
            throw new GenerationException(
                'Lambda returned empty output. ' + (err != null ? 'Error: ' + err : '')
            );
        }
        return b64;
    }

    /**
     * Renders the merged document in the requested format.
     *
     * The merge itself ALWAYS asks the doc-gen Lambda for DOCX, because that step
     * only substitutes merge tags and leaves the template's fonts untouched. When a
     * PDF is wanted, that DOCX is then converted by the STAMPING Lambda — the only
     * renderer we can ship fonts to (see lambda-src/docfonts/).
     *
     * Letting doc-gen produce the PDF instead re-introduces font substitution: it
     * has no access to the template's fonts, so text re-wraps, lines and pages are
     * added, and every anchored signature field ends up away from its content.
     *
     * It also keeps the preview and the generated output on ONE renderer, so the
     * text positions anchors were captured against still line up at generation time.
     */
    private static String renderMerged(
        String templateBase64,
        Map<String, Object> ctx,
        Map<String, Object> images,
        String fmt
    ) {
        String mergedDocx = callLambdaGenerate(templateBase64, ctx, images, 'DOCX');
        if (fmt != 'PDF') return mergedDocx;
        return convertDocxToPdfBase64(mergedDocx, 'merged.docx');
    }

    /**
     * DOCX base64 → PDF base64 via the stamping Lambda. Two hops, mirroring
     * TemplatePreviewPdfQueueable: convertToPdf returns a presigned S3 URL and
     * proxyUrl fetches those bytes server-side.
     *
     * Timeouts are deliberately modest — Apex allows only 120s of callout time per
     * transaction in total, and the merge above has already spent some of it.
     */
    private static String convertDocxToPdfBase64(String docxBase64, String filename) {
        String endpoint = SignForceConfigService.getLambdaEndpoint();
        if (String.isBlank(endpoint)) {
            throw new GenerationException(
                'Stamping Lambda endpoint is not configured. Set SignForce_Config.Default.Lambda_Endpoint__c.'
            );
        }
        Map<String, Object> config = SignForceConfigService.getClientConfig();

        HttpRequest conv = new HttpRequest();
        conv.setEndpoint(endpoint);
        conv.setMethod('POST');
        conv.setHeader('Content-Type', 'application/json');
        conv.setTimeout(60000);
        conv.setBody(JSON.serialize(new Map<String, Object>{
            'action'   => 'convertToPdf',
            'orgId'    => config.get('orgId'),
            'docId'    => 'gen_' + String.valueOf(Datetime.now().getTime()),
            'base64'   => docxBase64,
            'filename' => filename
        }));
        HttpResponse convRes = new Http().send(conv);
        if (convRes.getStatusCode() != 200) {
            throw new GenerationException('PDF conversion failed (HTTP ' + convRes.getStatusCode() + ').');
        }
        Map<String, Object> convBody = (Map<String, Object>) JSON.deserializeUntyped(convRes.getBody());
        String url = (convBody.get('success') == true) ? (String) convBody.get('url') : null;
        if (String.isBlank(url)) {
            throw new GenerationException(
                'PDF conversion returned no URL. ' + String.valueOf(convBody.get('error'))
            );
        }

        HttpRequest fetchReq = new HttpRequest();
        fetchReq.setEndpoint(endpoint);
        fetchReq.setMethod('POST');
        fetchReq.setHeader('Content-Type', 'application/json');
        fetchReq.setTimeout(40000);
        fetchReq.setBody(JSON.serialize(new Map<String, String>{ 'proxyUrl' => url }));
        HttpResponse fetchRes = new Http().send(fetchReq);
        if (fetchRes.getStatusCode() != 200) {
            throw new GenerationException('PDF fetch failed (HTTP ' + fetchRes.getStatusCode() + ').');
        }
        Map<String, Object> fetchBody = (Map<String, Object>) JSON.deserializeUntyped(fetchRes.getBody());
        String pdfBase64 = (String) fetchBody.get('pdfBase64');
        if (String.isBlank(pdfBase64)) {
            throw new GenerationException('PDF fetch returned no data.');
        }
        return pdfBase64;
    }

    private static Id saveOutputFile(String renderedBase64, String filename, String fmt, Id recordId) {
        return saveOutputFileWithIds(renderedBase64, filename, fmt, recordId).get('contentDocumentId');
    }

    /**
     * Same as saveOutputFile but returns both ContentDocumentId AND ContentVersionId.
     * The cvId lets the LWC preview the file via /apex/PDFPreview?cvId=... without
     * an extra Apex round-trip post-generation. Map keys:
     *   'contentDocumentId' → Id of the ContentDocument
     *   'contentVersionId'  → Id of the inserted ContentVersion (= cv.Id post-insert)
     */
    private static Map<String, Id> saveOutputFileWithIds(String renderedBase64, String filename, String fmt, Id recordId) {
        ContentVersion cv = new ContentVersion();
        cv.Title         = filename;
        cv.PathOnClient  = filename;
        cv.VersionData   = EncodingUtil.base64Decode(renderedBase64);
        cv.Origin        = 'H';
        Database.insert(cv, true, AccessLevel.USER_MODE);

        ContentVersion inserted = [
            SELECT Id, ContentDocumentId
            FROM ContentVersion WHERE Id = :cv.Id WITH USER_MODE LIMIT 1
        ];

        ContentDocumentLink cdl = new ContentDocumentLink();
        cdl.ContentDocumentId = inserted.ContentDocumentId;
        cdl.LinkedEntityId    = recordId;
        cdl.ShareType         = 'V';
        cdl.Visibility        = 'AllUsers';
        Database.insert(cdl, true, AccessLevel.USER_MODE);

        // Mirror the generated document to any connected cloud provider. Both
        // callers (single generate and the bulk batch, scope 1) reach this in a
        // transaction that has not enqueued a queueable yet, so the batch
        // context's one-child limit holds. Callout-after-DML is why this cannot
        // push inline. Best-effort: a failed enqueue must not fail the generation.
        if (!Test.isRunningTest()) {
            try {
                if (IntegrationService.anyEnabled()) {
                    // Cloud copies are grouped by the source record's object —
                    // <destination>/Contact/, <destination>/Account/, … — so the
                    // Drive stays organised instead of one flat pile of files.
                    String cloudFolder = null;
                    if (recordId != null) {
                        cloudFolder = recordId.getSobjectType().getDescribe().getLabel();
                    }
                    System.enqueueJob(new SignForceCloudPushQueueable(inserted.Id, cloudFolder));
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, 'Cloud push enqueue failed (non-fatal): ' + e.getMessage());
            }
        }

        return new Map<String, Id>{
            'contentDocumentId' => inserted.ContentDocumentId,
            'contentVersionId'  => inserted.Id
        };
    }

    /**
     * Renders the filename pattern with merge values and applies the right
     * extension based on output format.
     *
     * Fallback (when pattern is blank or no tags resolve) uses the record's
     * Name, NOT its Id — so users see "Employee NDA - Burlington Textiles"
     * rather than "Employee NDA - 001dN00000q7hC7QAI".
     *
     * Deduplication (file 2, 3, 4...) is handled separately in
     * dedupeFilename(), called AFTER this method by the caller.
     */
    private static String renderFilename(Document_Template__c tpl, Map<String, Object> ctx, String fmt) {
        String patternStr = tpl.Output_Filename_Pattern__c;

        // Prefer the record Name over Id for human-readable filenames.
        // Most standard objects (Account, Contact, Opportunity, etc.) have a
        // Name field; falls back to Id only if Name is missing/blank.
        Object recordNameObj = ctx.get('Name');
        String recordName = (recordNameObj == null) ? '' : String.valueOf(recordNameObj).trim();
        String nameOrId = String.isNotBlank(recordName)
            ? recordName
            : String.valueOf(ctx.get('Id'));
        String fallback = tpl.Name + ' - ' + nameOrId;

        String resolved = String.isBlank(patternStr) ? fallback : patternStr;
        if (String.isNotBlank(patternStr)) {
            Pattern p = Pattern.compile('\\{\\{([^{}]+)\\}\\}');
            Matcher m = p.matcher(patternStr);
            String built = '';
            Integer last = 0;
            Boolean anyTagResolved = false;
            while (m.find()) {
                built += patternStr.substring(last, m.start());
                String tag = m.group(1).trim();
                Object v = ctx.get(tag);
                if (v != null && String.isNotBlank(String.valueOf(v))) {
                    built += String.valueOf(v);
                    anyTagResolved = true;
                }
                last = m.end();
            }
            built += patternStr.substring(last);

            // If the pattern had {{tags}} but none of them resolved to a value
            // (e.g. blank record, missing fields), fall back to "Template - Name"
            // instead of producing garbage like " - Agreement".
            resolved = (!anyTagResolved && patternStr.contains('{{'))
                ? fallback
                : built;
        }

        // Sanitize file-system-bad chars
        resolved = resolved.replaceAll('[\\\\/:*?"<>|\\r\\n\\t]', '_').trim();
        // Collapse multiple spaces left after empty merge tags
        resolved = resolved.replaceAll('\\s+', ' ').trim();
        // Trim leading/trailing dashes that result from empty merge tags
        resolved = resolved.replaceAll('^[\\s-]+|[\\s-]+$', '').trim();
        if (String.isBlank(resolved)) resolved = fallback;

        // Strip any extension the user might have added to the pattern, then
        // append the right one for the output format.
        String lower = resolved.toLowerCase();
        if (lower.endsWith('.docx')) resolved = resolved.substring(0, resolved.length() - 5);
        else if (lower.endsWith('.pdf')) resolved = resolved.substring(0, resolved.length() - 4);

        String ext = (fmt == 'PDF') ? '.pdf' : '.docx';
        resolved += ext;

        if (resolved.length() > 255) resolved = resolved.substring(0, 255 - ext.length()) + ext;
        return resolved;
    }

    /**
     * Deduplicates a filename against existing ContentDocuments linked to the
     * given record. If "Employee NDA - Burlington.docx" already exists, returns
     * "Employee NDA - Burlington 2.docx". If 2 also exists, returns 3, etc.
     *
     * Logic:
     *   - Split filename into base + extension
     *   - Query ContentVersion.Title for the latest version of every file
     *     linked to recordId (via ContentDocumentLink)
     *   - Find max counter already used for this base
     *   - Return base + " N" + extension (where N is next available number)
     *
     * Case-insensitive matching so "BURLINGTON" and "burlington" collide.
     */
    private static String dedupeFilename(String filename, Id recordId) {
        if (recordId == null || String.isBlank(filename)) return filename;

        // Split base + extension
        String base = filename;
        String ext = '';
        Integer dotIdx = filename.lastIndexOf('.');
        if (dotIdx > 0) {
            base = filename.substring(0, dotIdx);
            ext  = filename.substring(dotIdx); // includes the dot, e.g. ".docx"
        }

        Set<String> existingTitlesLower = takenTitlesFor(recordId);
        if (existingTitlesLower.isEmpty()) return filename; // nothing to clash with

        // Quick check: if the exact filename does NOT exist, return as-is
        if (!existingTitlesLower.contains(filename.toLowerCase())) return filename;

        // Filename clashes. Find the highest counter already used.
        // We look for titles that start with "<base> " followed by a number,
        // optionally followed by the same extension.
        String baseLower = base.toLowerCase();
        String extLower  = ext.toLowerCase();
        Integer maxCounter = 1; // because base (without counter) is essentially "1"

        // Manually escape regex meta-characters in base + ext (Apex doesn't
        // expose Pattern.quote). Without this, a base like "Q4 (Vendor)"
        // would break the regex.
        String baseEscaped = escapeRegex(baseLower);
        String extEscaped  = escapeRegex(extLower);
        // Accepts BOTH the bracketed form we write now, "Name (2).docx", and the
        // bare form earlier versions produced, "Name 2.docx" — otherwise a record
        // that already has "Name 2.docx" would get "Name (2).docx" next, and the
        // numbering would restart instead of continuing.
        Pattern counterPattern = Pattern.compile(
            '^' + baseEscaped + '\\s+\\(?(\\d+)\\)?' + extEscaped + '$'
        );

        for (String title : existingTitlesLower) {
            Matcher cm = counterPattern.matcher(title);
            if (cm.matches()) {
                try {
                    Integer n = Integer.valueOf(cm.group(1));
                    if (n > maxCounter) maxCounter = n;
                } catch (Exception ignore) {}
            }
        }

        // Next available counter, written the way a file manager would:
        // "Contract (2).docx", "Contract (3).docx".
        Integer next = maxCounter + 1;
        String newFilename = base + ' (' + next + ')' + ext;

        // Belt-and-suspenders: if that name is somehow taken too (someone
        // renamed files by hand), keep incrementing.
        while (existingTitlesLower.contains(newFilename.toLowerCase()) && next < 9999) {
            next++;
            newFilename = base + ' (' + next + ')' + ext;
        }

        return newFilename;
    }

    /**
     * Every filename already spoken for on this record, lower-cased.
     *
     * Two sources, because a generated document does not always land on the
     * source record:
     *
     *   1. Files linked to the record — the normal case, where the output is
     *      saved straight onto it.
     *   2. Filenames of earlier generations, read from Document_Generation_Log__c.
     *      When a template has Auto Create Agreement switched on, generate()
     *      deliberately does NOT save the file here; it goes to the new
     *      Agreement instead. Source 1 therefore sees nothing, and without this
     *      second source every generation from such a template came out with the
     *      identical name.
     *
     * Called before the current run's log row is inserted, so it never counts
     * the name being chosen right now.
     */
    private static Set<String> takenTitlesFor(Id recordId) {
        Set<String> taken = new Set<String>();

        Set<Id> docIds = new Set<Id>();
        for (ContentDocumentLink cdl : [
            SELECT ContentDocumentId
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :recordId
            WITH USER_MODE
        ]) {
            docIds.add(cdl.ContentDocumentId);
        }
        if (!docIds.isEmpty()) {
            for (ContentVersion cv : [
                SELECT Title
                FROM ContentVersion
                WHERE ContentDocumentId IN :docIds AND IsLatest = true
                WITH USER_MODE
            ]) {
                if (cv.Title != null) taken.add(cv.Title.toLowerCase());
            }
        }

        for (Document_Generation_Log__c prior : [
            SELECT Output_Filename__c
            FROM Document_Generation_Log__c
            WHERE Source_Record_Id__c = :recordId
            AND Output_Filename__c != null
            WITH USER_MODE
            ORDER BY CreatedDate DESC
            LIMIT 500
        ]) {
            taken.add(prior.Output_Filename__c.toLowerCase());
        }

        return taken;
    }

    /**
     * Escapes the regex meta-characters in a literal string so it can be
     * embedded safely inside a Pattern. Apex doesn't expose Pattern.quote(),
     * so we do it by hand. Covers the meta-chars that matter for filenames:
     *   \ ^ $ . | ? * + ( ) [ ] { }
     */
    private static String escapeRegex(String s) {
        if (String.isBlank(s)) return '';
        // Backslash MUST be replaced first, otherwise we'd double-escape
        // the backslashes inserted by subsequent replacements.
        String out = s.replace('\\', '\\\\');
        out = out.replace('^', '\\^');
        out = out.replace('$', '\\$');
        out = out.replace('.', '\\.');
        out = out.replace('|', '\\|');
        out = out.replace('?', '\\?');
        out = out.replace('*', '\\*');
        out = out.replace('+', '\\+');
        out = out.replace('(', '\\(');
        out = out.replace(')', '\\)');
        out = out.replace('[', '\\[');
        out = out.replace(']', '\\]');
        out = out.replace('{', '\\{');
        out = out.replace('}', '\\}');
        return out;
    }

    /**
     * Issue #9 fix — cache whether the optional Agreement__c source-tracking
     * fields exist on this org. Previously we wrapped every read/write in a
     * try/catch that returned null on ANY exception, with the comment
     * "fields may not exist yet." That meant real runtime errors (FLS,
     * permissions, locked records) were silently swallowed and the user
     * could end up with duplicate drafts or untagged agreements without
     * any error showing up.
     *
     * Now: we check field existence once via Schema describe (cheap, no
     * exception path), and let real runtime errors propagate normally.
     */
    private static Boolean SOURCE_FIELDS_PRESENT;
    private static Boolean sourceFieldsExist() {
        if (SOURCE_FIELDS_PRESENT != null) return SOURCE_FIELDS_PRESENT;
        try {
            // Typed reference auto-resolves the namespace in a managed package
            // (getGlobalDescribe() keys are namespaced, so .get('Agreement__c')
            //  would return null once packaged).
            Map<String, Schema.SObjectField> fm =
                Agreement__c.SObjectType.getDescribe().fields.getMap();
            // Namespace-agnostic: in a managed package the field-map keys can be
            // namespaced (ns__source_record_id__c), so match on the bare name too.
            SOURCE_FIELDS_PRESENT = hasField(fm, 'source_record_id__c')
                                 && hasField(fm, 'source_template__c');
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'sourceFieldsExist describe failed: ' + e.getMessage());
            SOURCE_FIELDS_PRESENT = false;
        }
        return SOURCE_FIELDS_PRESENT;
    }

    /**
     * Namespace-safe field-existence check. Works whether the describe map
     * keys are bare ('source_record_id__c') in an unmanaged org or namespaced
     * ('ns__source_record_id__c') in a managed package.
     */
    private static Boolean hasField(Map<String, Schema.SObjectField> fm, String bareName) {
        String target = bareName.toLowerCase();
        if (fm.containsKey(target)) return true;
        for (String k : fm.keySet()) {
            if (k.endsWith('__' + target)) return true;
        }
        return false;
    }

    /**
     * M5-1: lookup helper — find an existing Draft agreement that came from
     * the same source record + template, so the LWC can soft-warn before
     * creating yet another draft.
     *
     * Returns null if none, or if the optional Source_Record_Id__c /
     * Source_Template__c fields don't exist on Agreement__c yet.
     */
    private static Map<String, String> findExistingDraft(Id sourceRecordId, Id templateId) {
        if (sourceRecordId == null || templateId == null) return null;
        // Issue #9 fix — schema check up front instead of catch-all
        if (!sourceFieldsExist()) return null;

        // No try/catch around the actual query — if it fails for a real
        // reason (FLS, profile permissions, etc) we want to know.
        String soql =
            'SELECT Id, Name FROM Agreement__c '
            + 'WHERE Source_Record_Id__c = :sourceRecordId '
            + 'AND Source_Template__c = :templateId '
            + 'AND Status__c = \'Draft\' '
            + 'AND Is_Template__c = false '
            + 'ORDER BY CreatedDate DESC LIMIT 1';
        List<SObject> rows = Database.query(soql, AccessLevel.USER_MODE);
        if (rows.isEmpty()) return null;
        return new Map<String, String>{
            'id'   => (String) rows[0].get('Id'),
            'name' => (String) rows[0].get('Name')
        };
    }

    /**
     * M5-1: tag a freshly-created Agreement__c with its source record +
     * source template so future generations can detect duplicates.
     *
     * Called from generateDocument LWC right after AgreementController.createAgreement
     * returns the new agreement Id. This MUST be a separate method because:
     *   - AgreementController.createAgreement is shared with your manual wizard
     *     and we don't want to change its signature.
     *   - The new fields might not exist yet, and we want the LWC code to
     *     deploy cleanly regardless. Dynamic put + try/catch makes this safe.
     *
     * Wrapped so failures don't kill the auto-create flow — if tagging
     * fails, the user still gets a working agreement, they just won't get
     * the soft-duplicate warning on subsequent generations.
     */
    @AuraEnabled
    public static void tagAgreementSource(Id agreementId, Id sourceRecordId, Id templateId, Id generationLogId) {
        if (agreementId == null) return;

        // Issue #9 fix — if the optional fields don't exist on this org,
        // simply skip (this is the legitimate "fail silent so deploy is
        // forgiving" case). Anything else — permissions, locking,
        // validation rules — should propagate so the caller can show a
        // proper warning toast instead of mysteriously creating untagged
        // duplicates on every generate.
        if (!sourceFieldsExist()) {
            System.debug(LoggingLevel.INFO,
                'tagAgreementSource skipped: source tracking fields not deployed yet.');
            return;
        }

        List<SObject> existing = Database.query(
            'SELECT Id FROM Agreement__c WHERE Id = :agreementId LIMIT 1',
            AccessLevel.USER_MODE
        );
        if (existing.isEmpty()) return;

        SObject ag = existing[0];
        ag.put('Source_Record_Id__c', sourceRecordId);
        ag.put('Source_Template__c',  templateId);

        // Which generation run produced this agreement. The history screen used
        // to reconstruct that pairing from template + creation order, which put
        // the "Open Agreement" button on the wrong row as soon as one template
        // had been generated twice. Guarded like the fields above: an org
        // without the field simply skips it.
        if (generationLogId != null) {
            try {
                Map<String, Schema.SObjectField> fm =
                    Agreement__c.SObjectType.getDescribe().fields.getMap();
                if (hasField(fm, 'source_generation_log__c')) {
                    ag.put('Source_Generation_Log__c', String.valueOf(generationLogId));
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN,
                    'tagAgreementSource: log-link skipped — ' + e.getMessage());
            }
        }
        // Every caller (generateDocument LWC, DocumentHistoryController) wraps this
        // whole method in a non-fatal try/catch — tagging is best-effort by design,
        // so a thrown guard here behaves exactly like any other DML failure already
        // did: the agreement is still created, it just isn't tagged.
        SignForceFLS.requireUpdateable(Agreement__c.SObjectType);
        Database.update(ag, true, AccessLevel.USER_MODE);
    }

    /**
     * M5-2: fetch the full list of existing Draft agreements for a given
     * source record + template combination. Used by the LWC to populate
     * the "existing drafts" confirmation panel after a successful generation
     * when one or more drafts already exist.
     *
     * Returns up to 10 drafts ordered most recent first. Includes:
     *   - id, name           — for the table row + "Use this one" button
     *   - createdDate (ISO)  — formatted by the LWC for display
     *   - createdBy          — owner display name
     *   - hasDocument        — true if the agreement already has a file
     *
     * Uses dynamic SOQL so this code deploys cleanly even before the
     * Source_Record_Id__c / Source_Template__c fields exist on Agreement__c.
     */
    @AuraEnabled
    public static List<Map<String, Object>> listExistingDrafts(Id sourceRecordId, Id templateId) {
        List<Map<String, Object>> out = new List<Map<String, Object>>();
        if (sourceRecordId == null || templateId == null) return out;

        // Issue #9 fix — same approach as findExistingDraft / tagAgreementSource.
        // Skip cleanly if the schema isn't there yet; otherwise let real
        // errors propagate (the LWC has its own try/catch around this call
        // and treats failure as "no drafts" so it stays a soft warning,
        // but at least the error shows up in the console for the dev to
        // see and fix instead of being completely invisible).
        if (!sourceFieldsExist()) return out;

        String soql =
            'SELECT Id, Name, CreatedDate, CreatedBy.Name '
            + 'FROM Agreement__c '
            + 'WHERE Source_Record_Id__c = :sourceRecordId '
            + 'AND Source_Template__c = :templateId '
            + 'AND Status__c = \'Draft\' '
            + 'AND Is_Template__c = false '
            + 'ORDER BY CreatedDate DESC LIMIT 10';
        List<SObject> rows = Database.query(soql, AccessLevel.USER_MODE);
        if (rows.isEmpty()) return out;

        // Pre-fetch which agreements already have an Original document
        Set<Id> agIds = new Set<Id>();
        for (SObject r : rows) agIds.add((Id) r.get('Id'));
        Set<Id> withDoc = new Set<Id>();
        for (Agreement_Document__c d : [
            SELECT Agreement__c FROM Agreement_Document__c
            WHERE Agreement__c IN :agIds AND Document_Type__c = 'Original' WITH USER_MODE
        ]) {
            withDoc.add(d.Agreement__c);
        }

        for (SObject r : rows) {
            Id agId = (Id) r.get('Id');
            String createdByName = '';
            SObject createdBy = (SObject) r.getSObject('CreatedBy');
            if (createdBy != null) {
                createdByName = (String) createdBy.get('Name');
            }
            out.add(new Map<String, Object>{
                'id'           => String.valueOf(agId),
                'name'         => (String) r.get('Name'),
                'createdDate'  => r.get('CreatedDate'),
                'createdBy'    => createdByName,
                'hasDocument'  => withDoc.contains(agId)
            });
        }
        return out;
    }

    public class GenerationException extends Exception {}
}