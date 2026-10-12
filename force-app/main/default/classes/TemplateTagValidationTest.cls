/**
 * TemplateTagValidationTest — TemplateService.validateTemplateTags.
 *
 * The Tags tab tells the author, per merge tag, which field it will pull from
 * and — when nothing will — why. That promise only holds if the check here
 * agrees with the one MergeContextBuilder runs at generation time, so the
 * cases below are chosen to cover the shapes that resolve differently:
 * plain fields, dotted relationship paths, loops and the tags written inside
 * them, built-ins, and the ways each of those can be wrong.
 */
@IsTest
private class TemplateTagValidationTest {

    /** Rows keyed by tag name, for readable assertions. */
    private static Map<String, Map<String, Object>> validateByTag(Id templateId) {
        Map<String, Map<String, Object>> byTag = new Map<String, Map<String, Object>>();
        for (Map<String, Object> row : TemplateService.validateTemplateTags(templateId)) {
            byTag.put((String) row.get('tagName'), row);
        }
        return byTag;
    }

    private static Boolean isOk(Map<String, Object> row) {
        return row != null && row.get('ok') == true;
    }

    @IsTest
    static void realFieldReportsItsLabelAndObject() {
        Document_Template__c tpl = DocGenTestDataFactory.makeBasicTemplate('Account');
        DocGenTestDataFactory.addTag(tpl.Id, 'AccountNumber', 'Field');

        Test.startTest();
        Map<String, Map<String, Object>> rows = validateByTag(tpl.Id);
        Test.stopTest();

        Map<String, Object> r = rows.get('AccountNumber');
        Assert.isTrue(isOk(r), 'AccountNumber exists on Account and must resolve');
        Assert.isNotNull(r.get('label'), 'A resolved tag must carry the field label to show');
        Assert.areEqual('Account', r.get('objectLabel'), 'Should report the object it reads from');
        Assert.isNull(r.get('error'), 'A resolved tag must not carry an error');
    }

    /**
     * The whole point of the feature: a typo has to surface here rather than as
     * a failed generation later.
     */
    @IsTest
    static void unknownFieldIsReportedWithAReason() {
        Document_Template__c tpl = DocGenTestDataFactory.makeBasicTemplate('Account');
        DocGenTestDataFactory.addTag(tpl.Id, 'AccuontNumber', 'Field');

        Test.startTest();
        Map<String, Map<String, Object>> rows = validateByTag(tpl.Id);
        Test.stopTest();

        Map<String, Object> r = rows.get('AccuontNumber');
        Assert.isFalse(isOk(r), 'A misspelt field must not be reported as resolvable');
        String err = (String) r.get('error');
        Assert.isNotNull(err, 'A broken tag must explain itself');
        Assert.isTrue(err.contains('AccuontNumber'),
            'The message should name the tag that is wrong, got: ' + err);
    }

    /**
     * System fields are deliberately hidden from the field-reference panel, but
     * they merge perfectly well. Validating against that panel's list would have
     * flagged CreatedDate as missing — a false alarm on a working template.
     */
    @IsTest
    static void systemFieldsStillResolve() {
        Document_Template__c tpl = DocGenTestDataFactory.makeBasicTemplate('Account');
        DocGenTestDataFactory.addTag(tpl.Id, 'CreatedDate', 'Field');

        Test.startTest();
        Map<String, Map<String, Object>> rows = validateByTag(tpl.Id);
        Test.stopTest();

        Assert.isTrue(isOk(rows.get('CreatedDate')),
            'CreatedDate merges fine, so it must not be reported as broken');
    }

    @IsTest
    static void dottedRelationshipPathResolvesToTheRelatedObject() {
        Document_Template__c tpl = DocGenTestDataFactory.makeBasicTemplate('Account');
        DocGenTestDataFactory.addTag(tpl.Id, 'Owner.FirstName', 'Field');
        DocGenTestDataFactory.addTag(tpl.Id, 'Ownre.FirstName', 'Field');

        Test.startTest();
        Map<String, Map<String, Object>> rows = validateByTag(tpl.Id);
        Test.stopTest();

        Map<String, Object> good = rows.get('Owner.FirstName');
        Assert.isTrue(isOk(good), 'Owner.FirstName is a valid path from Account');
        Assert.areEqual('User', good.get('objectLabel'),
            'The label should name the object the value actually comes from');

        Map<String, Object> bad = rows.get('Ownre.FirstName');
        Assert.isFalse(isOk(bad), 'A misspelt relationship must be reported');
        Assert.isTrue(((String) bad.get('error')).contains('Ownre'),
            'The message should name the relationship that is wrong');
    }

    @IsTest
    static void builtinsResolveAndUnknownOnesDoNot() {
        Document_Template__c tpl = DocGenTestDataFactory.makeBasicTemplate('Account');
        DocGenTestDataFactory.addTag(tpl.Id, 'TODAY', 'Builtin');
        DocGenTestDataFactory.addTag(tpl.Id, 'USER.FullName', 'Builtin');
        DocGenTestDataFactory.addTag(tpl.Id, 'ORG.Name', 'Builtin');
        DocGenTestDataFactory.addTag(tpl.Id, 'USER.NotARealField', 'Builtin');
        DocGenTestDataFactory.addTag(tpl.Id, 'YESTERDAY', 'Builtin');

        Test.startTest();
        Map<String, Map<String, Object>> rows = validateByTag(tpl.Id);
        Test.stopTest();

        Assert.isTrue(isOk(rows.get('TODAY')), 'TODAY is a supported built-in');
        Assert.isTrue(isOk(rows.get('USER.FullName')), 'USER.FullName is served from UserInfo');
        Assert.isTrue(isOk(rows.get('ORG.Name')), 'ORG.Name is served from UserInfo');
        Assert.isFalse(isOk(rows.get('USER.NotARealField')),
            'A USER.* tag naming no real User field merges blank, so it must be flagged');
        Assert.isFalse(isOk(rows.get('YESTERDAY')),
            'YESTERDAY is not a built-in and must not be reported as one');
    }

    /**
     * A loop names a child relationship, and the tags inside it belong to the
     * CHILD object. Validating those against the template's own object would
     * condemn every correct loop body.
     */
    @IsTest
    static void loopChildrenValidateAgainstTheChildObject() {
        Document_Template__c tpl = DocGenTestDataFactory.makeBasicTemplate('Account');
        Document_Template_Field__c loopTag =
            DocGenTestDataFactory.addTag(tpl.Id, 'Contacts', 'Loop');

        Document_Template_Field__c inLoop =
            DocGenTestDataFactory.addTag(tpl.Id, 'FirstName', 'Field');
        inLoop.Loop_Parent__c = loopTag.Id;
        update inLoop;

        Test.startTest();
        Map<String, Map<String, Object>> rows = validateByTag(tpl.Id);
        Test.stopTest();

        Assert.isTrue(isOk(rows.get('Contacts')), 'Contacts is a real child relationship of Account');
        Assert.isTrue(isOk(rows.get('FirstName')),
            'FirstName exists on Contact; inside the Contacts loop it must resolve');
    }

    @IsTest
    static void unknownLoopIsReported() {
        Document_Template__c tpl = DocGenTestDataFactory.makeBasicTemplate('Account');
        DocGenTestDataFactory.addTag(tpl.Id, 'Widgets', 'Loop');

        Test.startTest();
        Map<String, Map<String, Object>> rows = validateByTag(tpl.Id);
        Test.stopTest();

        Assert.isFalse(isOk(rows.get('Widgets')),
            'Account has neither a Widgets child relationship nor a Widgets field');
    }

    /**
     * A template can outlive the object it targets — deleted, renamed, or simply
     * not visible to this user. That must read as "the object is gone", not as a
     * list of field typos.
     */
    @IsTest
    static void vanishedTargetObjectIsNamedInTheError() {
        Document_Template__c tpl = DocGenTestDataFactory.makeBasicTemplate('Not_A_Real_Object__c');
        DocGenTestDataFactory.addTag(tpl.Id, 'Name', 'Field');

        Test.startTest();
        Map<String, Map<String, Object>> rows = validateByTag(tpl.Id);
        Test.stopTest();

        Map<String, Object> r = rows.get('Name');
        Assert.isFalse(isOk(r), 'Nothing resolves against an object that is not there');
        Assert.isTrue(((String) r.get('error')).contains('Not_A_Real_Object__c'),
            'The message should name the missing object, got: ' + r.get('error'));
    }

    @IsTest
    static void everyTagGetsExactlyOneRow() {
        Document_Template__c tpl = DocGenTestDataFactory.makeBasicTemplate('Account');
        DocGenTestDataFactory.addTag(tpl.Id, 'Name', 'Field');
        DocGenTestDataFactory.addTag(tpl.Id, 'Industry', 'Field');
        DocGenTestDataFactory.addTag(tpl.Id, 'TODAY', 'Builtin');

        Test.startTest();
        List<Map<String, Object>> rows = TemplateService.validateTemplateTags(tpl.Id);
        Test.stopTest();

        Assert.areEqual(3, rows.size(), 'One row per detected tag, so the UI can key by id');
        for (Map<String, Object> row : rows) {
            Assert.isNotNull(row.get('id'), 'Rows are matched to the UI list by tag record id');
        }
    }

    @IsTest
    static void missingTemplateIsRejected() {
        Boolean threw = false;
        Test.startTest();
        try {
            TemplateService.validateTemplateTags(null);
        } catch (Exception e) {
            threw = true;
        }
        Test.stopTest();
        Assert.isTrue(threw, 'A null template id must be rejected, not silently return nothing');
    }
}