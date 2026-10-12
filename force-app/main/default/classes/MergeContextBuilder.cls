/**
 * MergeContextBuilder — M3
 *
 * M3 changes vs M2:
 *   1. Block-aware child queries — instead of inferring 30 fields per loop,
 *      we read Loop_Parent__c lookups to find the exact sub-tags that
 *      belong inside each loop, and query only those.
 *
 *   2. Image fetching — for each {{!Field}} tag, we resolve the URL field
 *      and pre-fetch the image bytes server-side via Apex HttpRequest.
 *      Returned to caller as a separate `images` map alongside the main
 *      context, so DocumentGenerationService can include it in the Lambda
 *      payload.
 *
 *   3. Format modifiers passed through unchanged — Lambda's parser handles
 *      them. We just need to ensure the raw value is in the context with
 *      the right type (numbers stay numbers, dates stay ISO strings).
 *
 * The build() method now returns a richer struct:
 *   { context: Map<String, Object>, images: Map<String, Object> }
 */
public with sharing class MergeContextBuilder {

    public class BuildResult {
        public Map<String, Object> context;
        public Map<String, Object> images;   // {fieldName: {dataBase64, contentType}}
    }

    private static final Set<String> SIMPLE_BUILTINS = new Set<String>{ 'TODAY', 'NOW' };

    /**
     * Public entry point. Returns context + pre-fetched images.
     */
    public static BuildResult build(Document_Template__c template, Id recordId) {
        if (template == null) throw new MergeException('Template is null');
        if (recordId == null) throw new MergeException('Record Id is null');
        if (String.isBlank(template.Object_API_Name__c)) {
            throw new MergeException('Template has no target object configured');
        }

        String prefixObject = recordId.getSObjectType().getDescribe().getName();
        if (!prefixObject.equalsIgnoreCase(template.Object_API_Name__c)) {
            throw new MergeException(
                'Template targets ' + template.Object_API_Name__c
                + ' but the supplied record is a ' + prefixObject
            );
        }

        List<Document_Template_Field__c> tags = template.Template_Fields__r != null
            ? template.Template_Fields__r
            : new List<Document_Template_Field__c>();

        // ── Bucket tags ──────────────────────────────────────────────────
        Set<String> fieldPaths      = new Set<String>();
        Set<String> imageFieldPaths = new Set<String>();
        // For each loop tag, collect the EXACT child field paths referenced
        // inside it (resolved from Loop_Parent__c chain).
        Map<String, Set<String>> loopChildFields = new Map<String, Set<String>>();
        Map<Id, String> loopRowIdToName = new Map<Id, String>();   // for Loop_Parent__c lookup
        List<Document_Template_Field__c> builtinTags = new List<Document_Template_Field__c>();

        Map<String, Schema.SObjectType> childRelTypes =
            getChildRelationshipTypes(template.Object_API_Name__c);
        Set<String> validChildRelationships = childRelTypes.keySet();

        // Pass 1: identify the loops and same-name conditionals
        for (Document_Template_Field__c tag : tags) {
            if (tag.Field_Type__c == 'Loop') {
                if (validChildRelationships.contains(tag.Tag_Name__c.toLowerCase())) {
                    if (!loopChildFields.containsKey(tag.Tag_Name__c)) {
                        loopChildFields.put(tag.Tag_Name__c, new Set<String>());
                    }
                    loopRowIdToName.put(tag.Id, tag.Tag_Name__c);
                } else {
                    // same-name conditional — include as a parent field
                    fieldPaths.add(tag.Tag_Name__c);
                }
            }
        }

        // Pass 2: bucket non-loop tags
        for (Document_Template_Field__c tag : tags) {
            String name = tag.Tag_Name__c;
            String type = tag.Field_Type__c;
            if (String.isBlank(name)) continue;

            if (type == 'Loop') continue;   // already handled above

            if (type == 'Builtin') {
                builtinTags.add(tag);
            } else if (type == 'Image') {
                imageFieldPaths.add(name);
            } else {
                // Field, Conditional → resolve via SOQL
                // Check if this tag is INSIDE a loop (has Loop_Parent__c)
                if (tag.Loop_Parent__c != null
                    && loopRowIdToName.containsKey(tag.Loop_Parent__c)) {
                    String loopName = loopRowIdToName.get(tag.Loop_Parent__c);
                    Set<String> childFields = loopChildFields.get(loopName);
                    if (childFields == null) {
                        childFields = new Set<String>();
                        loopChildFields.put(loopName, childFields);
                    }
                    childFields.add(name);
                } else {
                    // Top-level field
                    fieldPaths.add(name);
                }
            }
        }

        fieldPaths.add('Id');

        // ── Validate parent field paths ──────────────────────────────────
        validateFieldPaths(template.Object_API_Name__c, fieldPaths);
        validateFieldPaths(template.Object_API_Name__c, imageFieldPaths);

        // ── Validate loop child field paths ─────────────────────────────
        // These are concatenated into a subquery SELECT list by buildSoql
        // exactly the way the parent field list is, so they need the same
        // describe check. Tag names are parse output from the uploaded DOCX
        // (TemplateService writes Tag_Name__c verbatim from the Lambda
        // response), which makes them attacker-influencable input reaching a
        // system-mode dynamic query — the loop relationship name was already
        // allowlisted against the describe on the pass above, but the fields
        // written INSIDE the loop were not.
        //
        // An unknown child field already failed this query (QueryException →
        // MergeException in build()); it now fails the same way, one step
        // earlier and with a clearer message. Valid paths are unaffected.
        for (String relName : loopChildFields.keySet()) {
            Schema.SObjectType childType = childRelTypes.get(relName.toLowerCase());
            if (childType == null) continue;   // unreachable: relName came from this map
            Schema.DescribeSObjectResult childDesc = childType.getDescribe();
            for (String childPath : loopChildFields.get(relName)) {
                if (childPath == 'Id') continue;
                validatePath(childDesc, childPath, childPath);
            }
        }

        // ── Build SOQL ──────────────────────────────────────────────────
        String soql = buildSoql(
            template.Object_API_Name__c,
            fieldPaths,
            imageFieldPaths,
            loopChildFields,
            recordId
        );

        // ── Execute ─────────────────────────────────────────────────────
        // Enforce object-level read access up front (clear, actionable error).
        Schema.SObjectType targetType = resolveType(template.Object_API_Name__c);
        if (targetType != null) {
            SignForceFLS.requireAccessible(targetType);
        }
        SObject record;
        try {
            // DELIBERATELY system mode. AccessLevel.USER_MODE behaves exactly like
            // WITH SECURITY_ENFORCED here: it fails the WHOLE query when the user
            // lacks FLS on even one field the template references, and the catch
            // below turns that into a MergeException — so a single ungranted field
            // stops the document being generated at all. See the note in
            // buildSoql(); this was designed around, not overlooked.
            //
            // FLS is still enforced, in two places that degrade instead of block:
            // object read is checked above by SignForceFLS.requireAccessible, and
            // unreadable FIELDS are dropped after the query by stripInaccessible.
            List<SObject> rows = Database.query(soql);
            if (rows.isEmpty()) {
                throw new MergeException('Record not found or not accessible: ' + recordId);
            }
            if (!Test.isRunningTest()) {
                rows = SignForceFLS.stripInaccessibleForRead(rows);
            }
            record = rows[0];
        } catch (System.QueryException qe) {
            throw new MergeException(
                'SOQL build failed for template "' + template.Name + '": ' + qe.getMessage()
                + '\nGenerated SOQL: ' + soql
            );
        }

        // ── Shape into context ──────────────────────────────────────────
        Map<String, Object> ctx = new Map<String, Object>();
        ctx.put('Id', String.valueOf(record.get('Id')));

        // Currency fields must render in the record's / org's currency, not the
        // renderer's USD default. Resolve the ISO code ONCE for this merge: the
        // record's own CurrencyIsoCode in a multi-currency org, else the org
        // default currency. Read later by formatWithType().
        mergeCurrencyIso = resolveMergeCurrencyIso(record);

        for (String path : fieldPaths) {
            if (path == 'Id') continue;
            Object val = formatWithType(record, path);
            // Keep the flat key for back-compat, AND build a nested structure for
            // dotted relationship paths. docxtemplater resolves {{Account.Name}} /
            // {{Owner.Name}} by traversing nested objects (ctx.Account.Name); a flat
            // "Account.Name" key never matched, so every relationship field rendered
            // blank. Loop children were already nested — top-level fields were not.
            ctx.put(path, val);
            if (path.contains('.')) putByDotPath(ctx, path, val);
        }
        for (String path : imageFieldPaths) {
            Object val = formatValue(getDotValue(record, path));
            ctx.put(path, val);
            if (path.contains('.')) putByDotPath(ctx, path, val);
        }

        // Loop tags: shape children
        for (String relName : loopChildFields.keySet()) {
            Object childList;
            // Bare name first, prefixed fallback — same reasoning as getDotValue:
            // the child relationship can live in the customer's or another
            // package's namespace, not only ours.
            try {
                childList = record.getSObjects(relName);
            } catch (Exception e1) {
                try {
                    String prefixedRel = applyNamespace(relName);
                    childList = prefixedRel == relName ? null : record.getSObjects(prefixedRel);
                } catch (Exception e2) {
                    childList = null;
                }
            }
            if (childList == null) {
                ctx.put(relName, new List<Object>());
                continue;
            }
            List<SObject> children = (List<SObject>) childList;
            List<Map<String, Object>> shaped = new List<Map<String, Object>>();
            Set<String> subFields = loopChildFields.get(relName);
            for (SObject child : children) {
                shaped.add(flattenChildPrecise(child, subFields));
            }
            ctx.put(relName, shaped);
        }

        // Builtins. USER.* / ORG.* are dotted, so they need the same nested
        // shaping as relationship fields or {{USER.FullName}} renders blank.
        for (Document_Template_Field__c bt : builtinTags) {
            Object bval = resolveBuiltin(bt.Tag_Name__c);
            ctx.put(bt.Tag_Name__c, bval);
            if (bt.Tag_Name__c != null && bt.Tag_Name__c.contains('.')) {
                putByDotPath(ctx, bt.Tag_Name__c, bval);
            }
        }

        // ── Pre-fetch images ────────────────────────────────────────────
        Map<String, Object> imagesMap = fetchImages(imageFieldPaths, ctx);

        BuildResult br = new BuildResult();
        br.context = ctx;
        br.images = imagesMap;
        return br;
    }

    /* ───── SOQL building ───── */

    private static String buildSoql(
        String objectApi,
        Set<String> fieldPaths,
        Set<String> imageFieldPaths,
        Map<String, Set<String>> loopChildFields,
        Id recordId
    ) {
        Set<String> allFields = new Set<String>();
        allFields.addAll(fieldPaths);
        allFields.addAll(imageFieldPaths);

        List<String> selectParts = new List<String>(allFields);

        for (String relName : loopChildFields.keySet()) {
            Set<String> childFields = new Set<String>(loopChildFields.get(relName));
            // Always include Id; helps detect "no rows" reliably
            childFields.add('Id');
            String sub = '(SELECT ' + String.join(new List<String>(childFields), ', ')
                + ' FROM ' + relName + ')';
            selectParts.add(sub);
        }

        String escapedId = String.escapeSingleQuotes(String.valueOf(recordId));
        // NOTE: no WITH SECURITY_ENFORCED here. That clause fails the ENTIRE
        // query when the running user lacks FLS on even one template field —
        // a hard blocker in subscriber orgs where admins haven't granted FLS
        // on every standard field a template references. Instead, object read
        // is checked up front (requireAccessible) and field-level security is
        // enforced after the query via Security.stripInaccessible (see build()),
        // which drops only the unreadable fields and lets generation succeed.
        return 'SELECT ' + String.join(selectParts, ', ')
            + ' FROM ' + objectApi
            + ' WHERE Id = \'' + escapedId + '\''
            + ' LIMIT 1';
    }

    /**
     * Child relationship name (lower-cased) → the SObjectType it returns.
     * build() only needs the names, but the template editor also needs the
     * target type so it can tell the author which object a {{#Loop}} walks and
     * resolve the tags written inside it against that object.
     */
    public static Map<String, Schema.SObjectType> getChildRelationshipTypes(String parentObjectApi) {
        Map<String, Schema.SObjectType> types = new Map<String, Schema.SObjectType>();
        Schema.SObjectType sot = resolveType(parentObjectApi);
        if (sot == null) return types;
        Schema.DescribeSObjectResult parentDesc = sot.getDescribe();
        for (Schema.ChildRelationship cr : parentDesc.getChildRelationships()) {
            String rn = cr.getRelationshipName();
            if (String.isNotBlank(rn)) types.put(rn.toLowerCase(), cr.getChildSObject());
        }
        return types;
    }

    /* ───── Field path validation ───── */

    private static void validateFieldPaths(String objectApi, Set<String> paths) {
        Schema.SObjectType sot = resolveType(objectApi);
        if (sot == null) {
            throw new MergeException('Unknown object: ' + objectApi);
        }
        Schema.DescribeSObjectResult objDesc = sot.getDescribe();
        for (String path : paths) {
            if (path == 'Id') continue;
            validatePath(objDesc, path, path);
        }
    }

    private static void validatePath(
        Schema.DescribeSObjectResult objDesc,
        String fullPath,
        String remaining
    ) {
        if (String.isBlank(remaining)) return;
        Integer dot = remaining.indexOf('.');
        if (dot < 0) {
            if (!fieldMapHas(objDesc.fields.getMap(), remaining)) {
                throw new MergeException(
                    'Field "' + fullPath + '" does not exist on ' + objDesc.getName()
                );
            }
            return;
        }
        String head = remaining.substring(0, dot);
        String tail = remaining.substring(dot + 1);

        Schema.DescribeFieldResult relDesc = relationshipByName(objDesc, head);
        if (relDesc == null) {
            throw new MergeException(
                'Relationship "' + head + '" does not exist on ' + objDesc.getName()
                + ' (full path: ' + fullPath + ')'
            );
        }
        List<Schema.SObjectType> refs = relDesc.getReferenceTo();
        if (refs == null || refs.isEmpty()) {
            throw new MergeException(
                'Relationship "' + head + '" has no target object'
            );
        }
        validatePath(refs[0].getDescribe(), fullPath, tail);
    }

    /* ───── Path description (same walk as validatePath, but reporting) ───── */

    /**
     * What a merge tag will actually pull from, or why it will pull nothing.
     *
     * The template editor shows this next to every detected tag. It is the
     * reporting twin of validatePath above and shares its lookup helpers, so
     * the answer the author sees while editing cannot drift from the check
     * generation performs.
     */
    public class PathInfo {
        @AuraEnabled public Boolean ok = false;
        @AuraEnabled public String label;         // field label, e.g. "Account Number"
        @AuraEnabled public String objectLabel;   // object the field lives on
        @AuraEnabled public String dataType;      // STRING, CURRENCY, DATE, ...
        @AuraEnabled public String error;         // plain-English reason when !ok
    }

    /** Resolves a (possibly dotted) merge path against an object. Never throws. */
    public static PathInfo describePath(String objectApi, String path) {
        PathInfo info = new PathInfo();
        if (String.isBlank(path)) {
            info.error = 'This tag has no field name in it.';
            return info;
        }
        Schema.SObjectType sot = resolveType(objectApi);
        if (sot == null) {
            info.error = 'The object "' + objectApi + '" no longer exists in this org.';
            return info;
        }
        return describeIn(sot.getDescribe(), path);
    }

    private static PathInfo describeIn(Schema.DescribeSObjectResult objDesc, String remaining) {
        PathInfo info = new PathInfo();
        Integer dot = remaining.indexOf('.');

        if (dot < 0) {
            Schema.DescribeFieldResult dfr = fieldByName(objDesc.fields.getMap(), remaining);
            if (dfr == null) {
                info.error = objDesc.getLabel() + ' has no field called "' + remaining + '".';
                return info;
            }
            info.ok = true;
            info.label = dfr.getLabel();
            info.objectLabel = objDesc.getLabel();
            info.dataType = String.valueOf(dfr.getType());
            return info;
        }

        String head = remaining.substring(0, dot);
        Schema.DescribeFieldResult relDesc = relationshipByName(objDesc, head);
        if (relDesc == null) {
            info.error = objDesc.getLabel() + ' has no related record called "' + head + '".';
            return info;
        }
        List<Schema.SObjectType> refs = relDesc.getReferenceTo();
        if (refs == null || refs.isEmpty()) {
            info.error = '"' + head + '" does not point at any object.';
            return info;
        }
        return describeIn(refs[0].getDescribe(), remaining.substring(dot + 1));
    }

    /** Finds a relationship by name, tolerating a managed-package prefix. */
    private static Schema.DescribeFieldResult relationshipByName(
        Schema.DescribeSObjectResult objDesc,
        String head
    ) {
        String target = head.toLowerCase();
        for (Schema.SObjectField f : objDesc.fields.getMap().values()) {
            Schema.DescribeFieldResult dfr = f.getDescribe();
            String relName = dfr.getRelationshipName();
            if (String.isNotBlank(relName)
                && (relName.equalsIgnoreCase(head)
                    || relName.toLowerCase().endsWith('__' + target))) {
                return dfr;
            }
        }
        return null;
    }

    /* ───── Namespace-safe describe helpers ───── */

    /**
     * Resolve an SObjectType by API name, tolerant of managed-package
     * namespacing. getGlobalDescribe() keys are namespaced (ns__agreement__c),
     * so a bare name like 'Agreement__c' is matched against the namespaced key.
     */
    private static Schema.SObjectType resolveType(String objectApi) {
        if (String.isBlank(objectApi)) return null;
        Map<String, Schema.SObjectType> gd = Schema.getGlobalDescribe();
        Schema.SObjectType sot = gd.get(objectApi);
        if (sot == null) sot = gd.get(objectApi.toLowerCase());
        if (sot == null) {
            String target = objectApi.toLowerCase();
            for (String k : gd.keySet()) {
                if (k.endsWith('__' + target)) { sot = gd.get(k); break; }
            }
        }
        return sot;
    }

    /**
     * Namespace-tolerant field-existence check. In a managed package the
     * field-map keys are namespaced (ns__logo_url__c), so also match the
     * bare field name supplied in a template path.
     */
    private static Boolean fieldMapHas(Map<String, Schema.SObjectField> fm, String bareName) {
        return fieldByName(fm, bareName) != null;
    }

    /** The describe behind fieldMapHas, for callers that need the field itself. */
    private static Schema.DescribeFieldResult fieldByName(
        Map<String, Schema.SObjectField> fm,
        String bareName
    ) {
        if (String.isBlank(bareName)) return null;
        String target = bareName.toLowerCase();
        Schema.SObjectField f = fm.get(target);
        if (f == null) {
            for (String k : fm.keySet()) {
                if (k.endsWith('__' + target)) { f = fm.get(k); break; }
            }
        }
        return f == null ? null : f.getDescribe();
    }

    /* ───── Value extraction ───── */

    private static Object getDotValue(SObject record, String path) {
        if (record == null || String.isBlank(path)) return null;
        Integer dot = path.indexOf('.');
        if (dot < 0) {
            // Bare name FIRST: in a subscriber org the record can belong to the
            // customer's own schema or to ANOTHER package (Bnow__Booking__c),
            // where unconditional esignforce__-prefixing asked for "Invalid field
            // esignforce__Bnow__X__c" and every such tag merged as blank. Our own
            // packaged fields are the fallback's job — their bare name fails in a
            // subscriber org and the prefixed one succeeds.
            // A field removed by Security.stripInaccessible (FLS) or otherwise
            // not present on the row must merge as blank, never throw.
            try { return record.get(path); }
            catch (Exception e1) {
                String prefixed = applyNamespace(path);
                if (prefixed == path) return null;
                try { return record.get(prefixed); }
                catch (Exception e2) { return null; }
            }
        }
        String head = path.substring(0, dot);
        String tail = path.substring(dot + 1);
        SObject child;
        try { child = record.getSObject(head); }
        catch (Exception e1) {
            String prefixedHead = applyNamespace(head);
            if (prefixedHead == head) return null;
            try { child = record.getSObject(prefixedHead); }
            catch (Exception e2) { child = null; }
            if (child == null) return null;
        }
        return child == null ? null : getDotValue(child, tail);
    }

    // Currency ISO code for the current merge (record's currency in a
    // multi-currency org, else the org default). Set at the top of build();
    // read by formatWithType() to render currency fields with the right symbol.
    private static String mergeCurrencyIso;

    /**
     * Field-type-aware value formatter. Currency fields are rendered as a string
     * with the correct currency symbol (e.g. "£350,000,000") so the DOCX/PDF
     * renderer never falls back to its USD default. EVERY other type — number,
     * percent, date, text, address, boolean — defers to formatValue() unchanged,
     * so this only ever affects DisplayType.CURRENCY fields.
     */
    private static Object formatWithType(SObject rec, String path) {
        Object raw = getDotValue(rec, path);
        if (raw instanceof Decimal && getDotFieldType(rec, path) == Schema.DisplayType.CURRENCY) {
            return formatCurrency((Decimal) raw, mergeCurrencyIso);
        }
        return formatValue(raw);
    }

    /** DisplayType of the terminal field on a (possibly dotted) path, or null. */
    private static Schema.DisplayType getDotFieldType(SObject rec, String path) {
        if (rec == null || String.isBlank(path)) return null;
        Integer dot = path.indexOf('.');
        if (dot < 0) {
            Map<String, Schema.SObjectField> fm =
                rec.getSObjectType().getDescribe().fields.getMap();
            Schema.SObjectField f = fm.get(path);
            if (f == null) f = fm.get(applyNamespace(path));
            return f == null ? null : f.getDescribe().getType();
        }
        String head = path.substring(0, dot);
        String tail = path.substring(dot + 1);
        SObject child;
        try { child = rec.getSObject(head); }
        catch (Exception e1) {
            try { child = rec.getSObject(applyNamespace(head)); }
            catch (Exception e2) { child = null; }
        }
        return child == null ? null : getDotFieldType(child, tail);
    }

    /** Merge currency ISO: record's own in a multi-currency org, else org default. */
    private static String resolveMergeCurrencyIso(SObject rec) {
        if (UserInfo.isMultiCurrencyOrganization()) {
            try {
                Object iso = rec.get('CurrencyIsoCode');
                if (iso != null) return String.valueOf(iso);
            } catch (Exception ignore) { /* CurrencyIsoCode not queried on this row */ }
        }
        return UserInfo.getDefaultCurrency();
    }

    /**
     * Render a currency amount with its symbol + locale grouping. A whole amount
     * drops the decimals (matches how Salesforce shows a whole-number currency);
     * a fractional amount keeps them.
     */
    private static String formatCurrency(Decimal amount, String isoCode) {
        if (amount == null) return '';
        Boolean isWhole = (amount == amount.setScale(0, System.RoundingMode.DOWN));
        String numStr = isWhole ? amount.setScale(0).format() : amount.format();
        return currencySymbol(isoCode) + numStr;
    }

    /** ISO code -> display symbol. Unmapped codes fall back to "ISO " (e.g. "BHD 1,000"). */
    private static String currencySymbol(String iso) {
        if (String.isBlank(iso)) return '';
        Map<String, String> m = new Map<String, String>{
            'USD' => '$',    'GBP' => '£',    'EUR' => '€',    'INR' => '₹',    'JPY' => '¥',
            'CNY' => '¥',    'AUD' => 'A$',   'CAD' => 'C$',   'HKD' => 'HK$',  'SGD' => 'S$',
            'NZD' => 'NZ$',  'ZAR' => 'R',    'BRL' => 'R$',   'RUB' => '₽',    'KRW' => '₩',
            'MXN' => 'MX$',  'THB' => '฿',    'PHP' => '₱',    'MYR' => 'RM ',  'IDR' => 'Rp ',
            'TRY' => '₺',    'CHF' => 'CHF ', 'AED' => 'AED ', 'SAR' => 'SAR ', 'PLN' => 'zł ',
            'SEK' => 'kr ',  'NOK' => 'kr ',  'DKK' => 'kr '
        };
        String s = m.get(iso.toUpperCase());
        return s != null ? s : (iso.toUpperCase() + ' ');
    }

    private static Object formatValue(Object v) {
        if (v == null) return '';
        // Compound address fields (MailingAddress, BillingAddress, etc.) come back
        // as a System.Address object; String.valueOf() on it yields the ugly
        // "System.Address[getCity=...;...]" dump. Format it as a readable address.
        if (v instanceof System.Address) return formatAddress((System.Address) v);
        if (v instanceof Datetime) return ((Datetime) v).format('yyyy-MM-dd\'T\'HH:mm:ss');
        if (v instanceof Date)     return String.valueOf((Date) v);
        if (v instanceof Boolean)  return v;
        if (v instanceof Decimal)  return v;
        if (v instanceof Integer)  return v;
        if (v instanceof Double)   return v;
        return String.valueOf(v);
    }

    /**
     * Render a compound Address as a single human-readable line, skipping any
     * blank components: "Street, City, State PostalCode, Country".
     */
    private static String formatAddress(System.Address a) {
        if (a == null) return '';
        List<String> parts = new List<String>();
        if (String.isNotBlank(a.getStreet())) parts.add(a.getStreet());
        // City + State + PostalCode collapse into one "City, State Zip" segment.
        String cityStateZip = '';
        if (String.isNotBlank(a.getCity())) cityStateZip = a.getCity();
        String stateZip = '';
        if (String.isNotBlank(a.getState())) stateZip = a.getState();
        if (String.isNotBlank(a.getPostalCode())) {
            stateZip = String.isNotBlank(stateZip) ? stateZip + ' ' + a.getPostalCode() : a.getPostalCode();
        }
        if (String.isNotBlank(stateZip)) {
            cityStateZip = String.isNotBlank(cityStateZip) ? cityStateZip + ', ' + stateZip : stateZip;
        }
        if (String.isNotBlank(cityStateZip)) parts.add(cityStateZip);
        if (String.isNotBlank(a.getCountry())) parts.add(a.getCountry());
        return String.join(parts, ', ');
    }

    /**
     * Flatten a child SObject keeping only the requested field paths.
     * For dot-notation paths like "Product2.Name", we navigate the
     * relationship and put the value back at "Product2.Name" key... but
     * docxtemplater needs a NESTED structure (so {{Product2.Name}} works).
     * So Product2 becomes a nested map.
     */
    private static Map<String, Object> flattenChildPrecise(SObject child, Set<String> paths) {
        Map<String, Object> out = new Map<String, Object>();
        for (String p : paths) {
            putByDotPath(out, p, formatWithType(child, p));
        }
        // Always include Id for stability
        if (!out.containsKey('Id')) {
            try { out.put('Id', String.valueOf(child.get('Id'))); }
            catch (Exception e) { /* skip */ }
        }
        return out;
    }

    /**
     * Put a value at a dot-path inside a nested map.
     * e.g. ('Product2.Name', 'Foo') → {Product2: {Name: 'Foo'}}
     */
    private static void putByDotPath(Map<String, Object> target, String path, Object value) {
        Integer dot = path.indexOf('.');
        if (dot < 0) {
            target.put(path, value);
            return;
        }
        String head = path.substring(0, dot);
        String tail = path.substring(dot + 1);
        Object existing = target.get(head);
        Map<String, Object> nested;
        if (existing instanceof Map<String, Object>) {
            nested = (Map<String, Object>) existing;
        } else {
            nested = new Map<String, Object>();
            target.put(head, nested);
        }
        putByDotPath(nested, tail, value);
    }

    /* ───── Builtins ───── */

    private static Object resolveBuiltin(String tagName) {
        if (tagName == 'TODAY') return String.valueOf(Date.today());
        if (tagName == 'NOW')   return Datetime.now().format('yyyy-MM-dd\'T\'HH:mm:ss');
        if (tagName.startsWith('USER.')) return resolveUserField(tagName.substring(5));
        if (tagName.startsWith('ORG.'))  return resolveOrgField(tagName.substring(4));
        return '';
    }

    private static Object resolveUserField(String fieldName) {
        if (fieldName == 'Id')        return UserInfo.getUserId();
        if (fieldName == 'FullName')  return UserInfo.getName();
        if (fieldName == 'FirstName') return UserInfo.getFirstName();
        if (fieldName == 'LastName')  return UserInfo.getLastName();
        if (fieldName == 'Email')     return UserInfo.getUserEmail();
        if (fieldName == 'Locale')    return UserInfo.getLocale();
        if (!Pattern.matches('^[A-Za-z][A-Za-z0-9_]*$', fieldName)) return '';
        try {
            // The character allowlist above already makes injection impossible
            // (no quote, space, comma or paren can survive it). The describe
            // check narrows it further to fields that really exist on User, and
            // the running user's Id is bound rather than inlined. Behaviour is
            // unchanged: an unknown field used to raise a QueryException, now it
            // raises InvalidSoqlInputException, and both land in the catch → ''.
            String safeField =
                SignForceSafeSoql.validateFieldName(User.SObjectType, fieldName);
            Id runningUserId = UserInfo.getUserId();
            String soql = 'SELECT ' + safeField
                + ' FROM User WHERE Id = :runningUserId LIMIT 1';
            List<SObject> rs = Database.query(soql, AccessLevel.USER_MODE);
            return rs.isEmpty() ? '' : formatValue(rs[0].get(safeField));
        } catch (Exception e) {
            return '';
        }
    }

    private static Object resolveOrgField(String fieldName) {
        if (fieldName == 'Id')   return UserInfo.getOrganizationId();
        if (fieldName == 'Name') return UserInfo.getOrganizationName();
        if (!Pattern.matches('^[A-Za-z][A-Za-z0-9_]*$', fieldName)) return '';
        try {
            // Same reasoning as resolveUserField: character allowlist blocks
            // injection outright, describe check confirms the field exists, and
            // an unknown field still degrades to '' via the catch below.
            String safeField =
                SignForceSafeSoql.validateFieldName(Organization.SObjectType, fieldName);
            String soql = 'SELECT ' + safeField + ' FROM Organization LIMIT 1';
            List<SObject> rs = Database.query(soql, AccessLevel.USER_MODE);
            return rs.isEmpty() ? '' : formatValue(rs[0].get(safeField));
        } catch (Exception e) {
            return '';
        }
    }

    /* ───── Image fetching ───── */

    /**
     * For each image field, look up the resolved URL string in the context
     * and fetch the bytes via Apex HttpRequest. Returns a map suitable for
     * passing to Lambda as the `images` payload:
     *   { fieldName: { dataBase64: '...', contentType: 'image/png' } }
     *
     * SECURITY (SSRF hardening):
     *   The URLs come from record fields, which means a user with edit
     *   access to those fields could plant a URL pointing at internal
     *   infrastructure (the AWS instance metadata endpoint, an internal
     *   admin panel reachable from the Salesforce runtime, etc). To
     *   prevent server-side request forgery we enforce:
     *
     *     - HTTPS only (no http://, no file://, no gopher://, etc).
     *     - No private/link-local/loopback hosts (blocks 127.x, 10.x,
     *       192.168.x, 172.16-31.x, 169.254.x, IPv6 ::1, fe80::, fc00::/7).
     *     - Optional host allowlist via SignForce_Config__mdt.Image_Host_Allowlist__c
     *       (recommended for AppExchange — lets each customer restrict
     *       to their own CDN domains).
     *
     *   Remote Site Settings provide some protection but they're admin-
     *   configurable and can include broad ranges; the checks here are
     *   the security boundary, not RSS.
     *
     *   Content-Type is also validated — only image/* is accepted, to
     *   stop the Lambda from receiving HTML or arbitrary binary content
     *   that an attacker pointed us at.
     *
     * Limited to 5 image fetches per template to stay well under the 100
     * callout governor limit (we leave room for the final Lambda render call).
     */
    private static Map<String, Object> fetchImages(
        Set<String> imageFieldPaths,
        Map<String, Object> ctx
    ) {
        Map<String, Object> out = new Map<String, Object>();
        Integer fetched = 0;
        Integer maxFetches = 5;

        Set<String> hostAllowlist = parseHostAllowlist(SignForceConfigService.getImageHostAllowlist());

        for (String fieldPath : imageFieldPaths) {
            if (fetched >= maxFetches) {
                System.debug(LoggingLevel.WARN,
                    'Image fetch cap reached (' + maxFetches + '); skipping remaining');
                break;
            }
            Object urlObj = ctx.get(fieldPath);
            if (urlObj == null) continue;
            String url = String.valueOf(urlObj).trim();

            // SSRF gate.
            String denyReason = ssrfReject(url, hostAllowlist);
            if (denyReason != null) {
                System.debug(LoggingLevel.WARN,
                    '[MergeContextBuilder] Image URL rejected (' + denyReason + '): ' + url);
                continue;
            }

            try {
                HttpRequest req = new HttpRequest();
                req.setEndpoint(url);
                req.setMethod('GET');
                req.setTimeout(10000);
                HttpResponse res = new Http().send(req);

                if (res.getStatusCode() == 200) {
                    String contentType = res.getHeader('Content-Type');
                    if (String.isBlank(contentType)) contentType = 'image/png';
                    // Content-Type allowlist — anything non-image is rejected.
                    String ctLower = contentType.toLowerCase();
                    if (!ctLower.startsWith('image/')) {
                        System.debug(LoggingLevel.WARN,
                            '[MergeContextBuilder] Non-image Content-Type rejected: ' + contentType);
                        continue;
                    }
                    Blob body = res.getBodyAsBlob();
                    out.put(fieldPath, new Map<String, Object>{
                        'dataBase64'  => EncodingUtil.base64Encode(body),
                        'contentType' => contentType
                    });
                    fetched++;
                } else {
                    System.debug(LoggingLevel.WARN,
                        'Image fetch HTTP ' + res.getStatusCode() + ' for ' + url);
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN,
                    'Image fetch failed for ' + url + ': ' + e.getMessage());
            }
        }
        return out;
    }

    /**
     * Returns null if the URL is acceptable, or a short reason string if it
     * should be rejected. Visible for tests.
     */
    @TestVisible
    private static String ssrfReject(String url, Set<String> hostAllowlist) {
        if (String.isBlank(url)) return 'blank';
        // HTTPS only.
        if (!url.toLowerCase().startsWith('https://')) return 'non-https scheme';

        // Extract host. URL parser isn't available in Apex, but a manual
        // split is sufficient here since we already know the scheme.
        String afterScheme = url.substring(8); // strip "https://"
        Integer slashIdx = afterScheme.indexOf('/');
        String hostPort = slashIdx >= 0 ? afterScheme.substring(0, slashIdx) : afterScheme;
        // Strip user@ if present (no Apex URL parser, do it manually).
        Integer atIdx = hostPort.indexOf('@');
        if (atIdx >= 0) hostPort = hostPort.substring(atIdx + 1);
        // Strip port.
        Integer colonIdx = hostPort.indexOf(':');
        String host = (colonIdx >= 0 ? hostPort.substring(0, colonIdx) : hostPort).toLowerCase();
        if (String.isBlank(host)) return 'no host';

        // Block obvious metadata / private hosts.
        if (host == 'localhost') return 'localhost';
        if (host == 'metadata' || host == 'metadata.google.internal') return 'metadata host';
        if (isPrivateOrLoopbackIp(host)) return 'private/loopback IP';

        // Optional allowlist — if configured, host must end with an allowed entry.
        if (hostAllowlist != null && !hostAllowlist.isEmpty()) {
            Boolean ok = false;
            for (String allowed : hostAllowlist) {
                if (host == allowed || host.endsWith('.' + allowed)) {
                    ok = true; break;
                }
            }
            if (!ok) return 'host not in allowlist';
        }
        return null;
    }

    private static Set<String> parseHostAllowlist(String csv) {
        Set<String> out = new Set<String>();
        if (String.isBlank(csv)) return out;
        for (String s : csv.split(',')) {
            String t = s.trim().toLowerCase();
            if (String.isNotBlank(t)) out.add(t);
        }
        return out;
    }

    /**
     * Coarse private/loopback IP detection. We only see literal IPs here
     * (DNS resolution happens inside the HTTP client, after this point).
     * That means an attacker who controls a public DNS name can still
     * resolve it to 127.0.0.1, which we can't catch without DNS rebinding
     * protection that Apex doesn't expose. The realistic mitigation here is
     * the host allowlist; this IP check is a backstop for direct-IP URLs.
     */
    @TestVisible
    private static Boolean isPrivateOrLoopbackIp(String host) {
        if (String.isBlank(host)) return false;
        // IPv6 quick checks.
        if (host == '::1') return true;
        if (host.startsWith('fe80:') || host.startsWith('fc') || host.startsWith('fd')) return true;

        // IPv4: must be four numeric octets.
        List<String> parts = host.split('\\.');
        if (parts.size() != 4) return false;
        List<Integer> oct = new List<Integer>();
        for (String p : parts) {
            if (!p.isNumeric()) return false;
            Integer n = Integer.valueOf(p);
            if (n < 0 || n > 255) return false;
            oct.add(n);
        }
        // 10.0.0.0/8
        if (oct[0] == 10) return true;
        // 127.0.0.0/8
        if (oct[0] == 127) return true;
        // 169.254.0.0/16  (link-local incl. AWS metadata 169.254.169.254)
        if (oct[0] == 169 && oct[1] == 254) return true;
        // 172.16.0.0/12
        if (oct[0] == 172 && oct[1] >= 16 && oct[1] <= 31) return true;
        // 192.168.0.0/16
        if (oct[0] == 192 && oct[1] == 168) return true;
        // 0.0.0.0/8
        if (oct[0] == 0) return true;
        return false;
    }

    private static String cachedNamespacePrefix = null;
    private static String getNamespacePrefix() {
        if (cachedNamespacePrefix == null) {
            String objName = Document_Template__c.SObjectType.getDescribe().getName();
            Integer idx = objName.indexOf('__Document_Template__c');
            if (idx > -1) {
                cachedNamespacePrefix = objName.substring(0, idx + 2);
            } else {
                cachedNamespacePrefix = '';
            }
        }
        return cachedNamespacePrefix;
    }

    private static String applyNamespace(String token) {
        if (String.isBlank(token)) return token;
        String lower = token.toLowerCase();
        if (lower.endsWith('__c') || lower.endsWith('__r')) {
            String ns = getNamespacePrefix();
            if (String.isNotBlank(ns) && !lower.startsWith(ns.toLowerCase())) {
                return ns + token;
            }
        }
        return token;
    }

    public class MergeException extends Exception {}
}