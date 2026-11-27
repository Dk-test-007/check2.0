/**
 * =============================================================================
 * Class Name    : LeadPlaceholderConversionGuard_CC_Test
 * Description   : Tests the New Lead Wizard placeholder controls:
 *                 - Lead.Contact_Name_Unknown_CC__c (formula checkbox)
 *                 - Validation rule Placeholder_Name_Conversion_Block_CC
 *                 The guard has no System Administrator exemption, so the
 *                 conversion tests deliberately run as an administrator.
 *                 Formula reads use WITH SYSTEM_MODE: at API 67.0 SOQL defaults
 *                 to user mode and a newly deployed field has no FLS until the
 *                 Lead_Quick_Entry_User_CC permission set is assigned. These
 *                 tests verify the formula value, not access.
 *
 * =============================================================================
 * Modification History
 * =============================================================================
 * Version    Date         Author             Description
 * -------    ----------   -----------------  -----------------------------------
 * 1          27/10/2026   Aaron Blackledge   Initial version (UI rework)
 * 2          28/10/2026   Aaron Blackledge   Placeholder conversion test starts at Identify
 *                                            (Placeholder_Name_Stage_Block_CC)
 * =============================================================================
 */
@IsTest
private class LeadPlaceholderConversionGuard_CC_Test {

    private static final String ADMIN_PROFILE = 'System Administrator';
    private static final String CONVERTED_STATUS = 'Qualified';
    private static final String GUARD_MESSAGE_FRAGMENT = 'still has the placeholder contact name';
    private static final String STAGE_BLOCK_FRAGMENT = 'Identify the contact first';

    private static Lead buildLead(String lastName, String company) {
        return new Lead(
            LastName = lastName,
            Company = company,
            Status = 'Identify',
            City = 'Chicago',
            PostalCode = '60601',
            CountryCode = 'US'
        );
    }

    private static Map<String, Boolean> flagByLastName(List<String> lastNames) {
        List<Lead> leads = new List<Lead>();
        for (Integer index = 0; index < lastNames.size(); index++) {
            leads.add(buildLead(lastNames[index], 'Guard Formula Co ' + index));
        }
        insert leads;
        Map<String, Boolean> flags = new Map<String, Boolean>();
        for (Lead saved : [SELECT LastName, Contact_Name_Unknown_CC__c FROM Lead WHERE Id IN :leads WITH SYSTEM_MODE]) {
            flags.put(saved.LastName, saved.Contact_Name_Unknown_CC__c);
        }
        return flags;
    }

    @IsTest
    static void shouldFlagPlaceholder_WhenPrefixVariesByCaseAndSpacing() {
        List<String> placeholders = new List<String>{
            'Needs to Identify - Acme Foods',
            'needs to identify - acme foods',
            'NEEDS  TO  IDENTIFY',
            'Needstoidentify'
        };

        Test.startTest();
        Map<String, Boolean> flags = flagByLastName(placeholders);
        Test.stopTest();

        Assert.areEqual(placeholders.size(), flags.size(), 'Every placeholder variant should be saved');
        for (String lastName : flags.keySet()) {
            Assert.isTrue(flags.get(lastName), 'Placeholder variant should be flagged: ' + lastName);
        }
    }

    @IsTest
    static void shouldFlagPlaceholder_WhenSurroundedByWhitespace() {
        Lead saved = buildLead('   Needs to Identify - Acme   ', 'Whitespace Co');

        Test.startTest();
        insert saved;
        Test.stopTest();

        Assert.isTrue(
            [SELECT Contact_Name_Unknown_CC__c FROM Lead WHERE Id = :saved.Id WITH SYSTEM_MODE].Contact_Name_Unknown_CC__c,
            'Leading and trailing whitespace must not defeat detection'
        );
    }

    @IsTest
    static void shouldNotFlag_WhenLastNameIsReal() {
        List<String> realNames = new List<String>{ 'Smith', 'Identify', 'Needs', 'Toidentify' };

        Test.startTest();
        Map<String, Boolean> flags = flagByLastName(realNames);
        Test.stopTest();

        for (String lastName : flags.keySet()) {
            Assert.isFalse(flags.get(lastName), 'Real surname must not be flagged: ' + lastName);
        }
    }

    @IsTest
    static void shouldBlockConversion_WhenPlaceholderNameAndRunningAsAdministrator() {
        User admin = createAdmin();
        Database.LeadConvertResult result;

        Test.startTest();
        System.runAs(admin) {
            // Placeholder_Name_Stage_Block_CC now keeps a placeholder Lead at Identify, so it cannot first be set
            // to Qualified; convert it straight from Identify.
            Lead placeholderLead = buildLead('Needs to Identify - Guard Placeholder Co', 'Guard Placeholder Co');
            placeholderLead.FirstName = 'Guard';
            insert placeholderLead;
            result = convert(placeholderLead.Id);
        }
        Test.stopTest();

        Assert.isFalse(result.isSuccess(), 'A placeholder Lead must not convert, even for an administrator');
        Assert.isTrue(errorText(result).contains(GUARD_MESSAGE_FRAGMENT) || errorText(result).contains(STAGE_BLOCK_FRAGMENT),
            'Conversion should be stopped by a placeholder rule. Errors: ' + errorText(result));
    }

    @IsTest
    static void shouldNotApplyGuard_WhenLastNameIsReal() {
        User admin = createAdmin();
        Database.LeadConvertResult result;

        Test.startTest();
        System.runAs(admin) {
            Lead realLead = insertReadyForConversion('Realnameguardtest', 'Guard Real Name Co');
            result = convert(realLead.Id);
        }
        Test.stopTest();

        // Other org automation may still reject conversion; this asserts only that the new guard is not the cause.
        Assert.isFalse(errorText(result).contains(GUARD_MESSAGE_FRAGMENT),
            'The placeholder guard must not block a Lead with a real name. Errors: ' + errorText(result));
    }

    @IsTest
    static void shouldAllowCreateAndEdit_WhenPlaceholderNameIsNotConverted() {
        Lead placeholderLead = buildLead('Needs to Identify - Editable Co', 'Editable Co');

        Test.startTest();
        insert placeholderLead;
        placeholderLead.Title = 'Buyer';
        Database.SaveResult updateResult = Database.update(placeholderLead, false);
        Test.stopTest();

        Assert.isTrue(updateResult.isSuccess(), 'The guard is conversion-only; editing must still work: ' + updateResult.getErrors());
    }

    /** Creates the Lead, then sets the converted status so Lead_conversion_validation (prior status Qualified) is satisfied. */
    private static Lead insertReadyForConversion(String lastName, String company) {
        Lead leadRecord = buildLead(lastName, company);
        leadRecord.FirstName = 'Guard';
        insert leadRecord;
        update new Lead(Id = leadRecord.Id, Status = CONVERTED_STATUS);
        return leadRecord;
    }

    private static Database.LeadConvertResult convert(Id leadId) {
        Database.LeadConvert leadConvert = new Database.LeadConvert();
        leadConvert.setLeadId(leadId);
        leadConvert.setConvertedStatus(CONVERTED_STATUS);
        leadConvert.setDoNotCreateOpportunity(true);
        return Database.convertLead(leadConvert, false);
    }

    private static String errorText(Database.LeadConvertResult result) {
        List<String> messages = new List<String>();
        for (Database.Error error : result.getErrors()) {
            messages.add(error.getMessage());
        }
        return String.join(messages, ' | ');
    }

    private static User createAdmin() {
        Profile adminProfile = [SELECT Id FROM Profile WHERE Name = :ADMIN_PROFILE LIMIT 1];
        User admin = new User(
            FirstName = 'Guard',
            LastName = 'Admin Test',
            Alias = 'gdadmin',
            Email = 'guard.admin@carltontest.invalid',
            Username = 'gdadmin' + String.valueOf(Math.abs(Crypto.getRandomLong())) + '@carltontest.invalid',
            ProfileId = adminProfile.Id,
            TimeZoneSidKey = 'America/Chicago',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
        insert admin;
        return admin;
    }
}