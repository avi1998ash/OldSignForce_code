/**
 * SignForceSafeSoqlTest — coverage for the SOQL input sanitizer.
 */
@isTest
private class SignForceSafeSoqlTest {

    // ─── validateObjectName ──────────────────────────────────────

    @isTest
    static void validateObjectName_validObject_returnsCanonical() {
        String got = SignForceSafeSoql.validateObjectName('Agreement__c');
        // Namespace-tolerant: canonical name is namespaced in a managed package
        // (NSIQ_SignForce__Agreement__c) but bare in an unmanaged org.
        System.assert(got.toLowerCase().endsWith('agreement__c'),
            'Expected canonical Agreement__c, got: ' + got);
    }

    @isTest
    static void validateObjectName_unknown_throws() {
        try {
            SignForceSafeSoql.validateObjectName('NotARealObject__c');
            System.assert(false, 'Should have thrown');
        } catch (SignForceSafeSoql.InvalidSoqlInputException e) {
            // expected
        }
    }

    @isTest
    static void validateObjectName_blank_throws() {
        try {
            SignForceSafeSoql.validateObjectName('');
            System.assert(false, 'Should have thrown on blank');
        } catch (SignForceSafeSoql.InvalidSoqlInputException e) {
            // expected
        }
        try {
            SignForceSafeSoql.validateObjectName(null);
            System.assert(false, 'Should have thrown on null');
        } catch (SignForceSafeSoql.InvalidSoqlInputException e) {
            // expected
        }
    }

    // ─── validateFieldName ───────────────────────────────────────

    @isTest
    static void validateFieldName_validField_returnsCanonical() {
        String got = SignForceSafeSoql.validateFieldName(
            Agreement__c.SObjectType, 'Status__c'
        );
        // Namespace-tolerant: canonical field name is namespaced in a managed
        // package (NSIQ_SignForce__Status__c) but bare in an unmanaged org.
        System.assert(got.toLowerCase().endsWith('status__c'),
            'Expected canonical Status__c, got: ' + got);
    }

    @isTest
    static void validateFieldName_unknown_throws() {
        try {
            SignForceSafeSoql.validateFieldName(
                Agreement__c.SObjectType, 'NotARealField__c'
            );
            System.assert(false, 'Should have thrown');
        } catch (SignForceSafeSoql.InvalidSoqlInputException e) {
            // expected
        }
    }

    @isTest
    static void validateFieldName_nullObjType_throws() {
        try {
            SignForceSafeSoql.validateFieldName(null, 'Anything');
            System.assert(false, 'Should have thrown on null objType');
        } catch (SignForceSafeSoql.InvalidSoqlInputException e) {
            // expected
        }
    }

    @isTest
    static void validateFieldNames_listAllValid_returnsList() {
        List<String> got = SignForceSafeSoql.validateFieldNames(
            Agreement__c.SObjectType,
            new List<String>{ 'Status__c', 'Name' }
        );
        System.assertEquals(2, got.size());
    }

    @isTest
    static void validateFieldNames_oneInvalid_throws() {
        try {
            SignForceSafeSoql.validateFieldNames(
                Agreement__c.SObjectType,
                new List<String>{ 'Status__c', 'NotARealField__c' }
            );
            System.assert(false, 'Should have thrown');
        } catch (SignForceSafeSoql.InvalidSoqlInputException e) {
            // expected
        }
    }

    // ─── validateSortDirection ───────────────────────────────────

    @isTest
    static void validateSortDirection_asc_returnsAsc() {
        System.assertEquals('ASC', SignForceSafeSoql.validateSortDirection('asc'));
        System.assertEquals('ASC', SignForceSafeSoql.validateSortDirection('ASC'));
        System.assertEquals('ASC', SignForceSafeSoql.validateSortDirection('Asc'));
    }

    @isTest
    static void validateSortDirection_desc_returnsDesc() {
        System.assertEquals('DESC', SignForceSafeSoql.validateSortDirection('desc'));
    }

    @isTest
    static void validateSortDirection_blank_returnsAsc() {
        System.assertEquals('ASC', SignForceSafeSoql.validateSortDirection(''));
        System.assertEquals('ASC', SignForceSafeSoql.validateSortDirection(null));
    }

    @isTest
    static void validateSortDirection_invalid_throws() {
        try {
            SignForceSafeSoql.validateSortDirection('SIDEWAYS');
            System.assert(false, 'Should have thrown');
        } catch (SignForceSafeSoql.InvalidSoqlInputException e) {
            // expected
        }
    }

    // ─── validateLimit ───────────────────────────────────────────

    @isTest
    static void validateLimit_inBounds_returnsValue() {
        System.assertEquals(50, SignForceSafeSoql.validateLimit(50, 200));
    }

    @isTest
    static void validateLimit_overMax_capsToMax() {
        System.assertEquals(200, SignForceSafeSoql.validateLimit(500, 200));
    }

    @isTest
    static void validateLimit_zeroOrNegative_returnsOne() {
        System.assertEquals(1, SignForceSafeSoql.validateLimit(0, 200));
        System.assertEquals(1, SignForceSafeSoql.validateLimit(-5, 200));
    }

    @isTest
    static void validateLimit_null_returnsOne() {
        System.assertEquals(1, SignForceSafeSoql.validateLimit(null, 200));
    }

    // ─── escapeLiteral ───────────────────────────────────────────

    @isTest
    static void escapeLiteral_singleQuote_isEscaped() {
        // Input: O'Brien (apostrophe in the middle)
        // Expected output from String.escapeSingleQuotes: O\'Brien
        // i.e. the apostrophe gets prefixed with a backslash.
        String input = 'O\'Brien';
        String got = SignForceSafeSoql.escapeLiteral(input);
        // The output should differ from input (escape happened)
        System.assertNotEquals(input, got, 'Escape should have modified the string');
        // And it should still contain "Brien"
        System.assert(got.contains('Brien'), 'Should still contain Brien: ' + got);
        // And it should contain a backslash now
        System.assert(got.contains('\\'), 'Should contain a backslash: ' + got);
    }

    @isTest
    static void escapeLiteral_blank_returnsBlank() {
        System.assertEquals('', SignForceSafeSoql.escapeLiteral(''));
        System.assertEquals('', SignForceSafeSoql.escapeLiteral(null));
    }

    @isTest
    static void escapeLiteral_normalString_unchanged() {
        System.assertEquals('hello',
            SignForceSafeSoql.escapeLiteral('hello'));
    }

    // ─── buildInClause ───────────────────────────────────────────

    @isTest
    static void buildInClause_listOfStrings_buildsCorrectClause() {
        String got = SignForceSafeSoql.buildInClause(
            new List<String>{ 'Draft', 'Sent' }
        );
        System.assertEquals('(\'Draft\', \'Sent\')', got);
    }

    @isTest
    static void buildInClause_emptyList_returnsEmptyParens() {
        System.assertEquals('()',
            SignForceSafeSoql.buildInClause(new List<String>()));
        System.assertEquals('()',
            SignForceSafeSoql.buildInClause(null));
    }

    @isTest
    static void buildInClause_valuesWithQuotes_areEscaped() {
        String got = SignForceSafeSoql.buildInClause(
            new List<String>{ 'O\'Brien', 'Normal' }
        );
        // Should contain a backslash (from the escape)
        System.assert(got.contains('\\'),
            'Should contain a backslash from escaping: ' + got);
        // Should still contain both names
        System.assert(got.contains('Brien'), got);
        System.assert(got.contains('Normal'), got);
    }
}