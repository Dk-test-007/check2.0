@IsTest
private class GuidancePathController_CC_Test {
    private static Guidance_Section_CC__mdt section(String name, String key, String context,
        String personaType, String personaValue, String action) {
        return new Guidance_Section_CC__mdt(
            DeveloperName = name, Object_Config_Developer_Name_CC__c = 'UnitTest',
            Active_CC__c = true, Context_Value_CC__c = context,
            Persona_Type_CC__c = personaType, Persona_Value_CC__c = personaValue,
            Section_Key_CC__c = key, Section_Heading_CC__c = name,
            Section_Text_CC__c = 'Guidance for ' + name, Section_Order_CC__c = 1,
            Display_Action_CC__c = action
        );
    }

    @IsTest
    static void returnsGuidanceForConfiguredAccount() {
        Account account = new Account(Name = 'ZZTEST Guidance Account');
        insert account;
        GuidancePathController_CC.testConfigurations = new List<Guidance_Object_Config_CC__mdt>{
            new Guidance_Object_Config_CC__mdt(
                DeveloperName = 'UnitTest', Active_CC__c = true,
                Object_API_Name_CC__c = 'Account', Context_Field_API_Name_CC__c = 'Type'
            )
        };
        GuidancePathController_CC.testSections = new List<Guidance_Section_CC__mdt>{
            section('General', 'intro', '*', 'GLOBAL', null, 'SHOW'),
            section('Customer', 'customer', 'Customer', 'GLOBAL', null, 'SHOW')
        };
        update new Account(Id = account.Id, Type = 'Customer');

        GuidancePathController_CC.GuidanceResponse response = GuidancePathController_CC.getGuidanceData(account.Id);
        Assert.isTrue(response.isConfigured);
        Assert.areEqual('Account', response.objectApiName);
        Assert.areEqual(2, response.sections.size());
        Assert.areEqual(0, GuidancePathController_CC.getGuidanceData(null).sections.size());
    }

    @IsTest
    static void resolvesContextAndPersonaPrecedence() {
        List<Guidance_Section_CC__mdt> options = new List<Guidance_Section_CC__mdt>{
            section('Global', 'step', '*', 'GLOBAL', null, 'SHOW'),
            section('Specific', 'step', 'Customer', 'GLOBAL', null, 'SHOW'),
            section('Profile', 'step', 'Customer', 'PROFILE', 'System Administrator', 'SHOW'),
            section('Hidden', 'hidden', '*', 'GLOBAL', null, 'HIDE'),
            section('WrongProfile', 'other', '*', 'PROFILE', 'No Such Profile', 'SHOW')
        };
        List<Guidance_Section_CC__mdt> resolved = GuidancePathController_CC.resolveApplicableSections(
            options, 'Customer', 'System Administrator');
        Assert.areEqual(1, resolved.size());
        Assert.areEqual('Profile', resolved[0].DeveloperName);
        Assert.areEqual(0, GuidancePathController_CC.resolveApplicableSections(
            options, null, 'System Administrator').size());
    }

    @IsTest
    static void invalidContextFieldIsRejected() {
        Account account = new Account(Name = 'ZZTEST Bad Guidance Config');
        insert account;
        GuidancePathController_CC.testConfigurations = new List<Guidance_Object_Config_CC__mdt>{
            new Guidance_Object_Config_CC__mdt(
                DeveloperName = 'UnitTest', Active_CC__c = true,
                Object_API_Name_CC__c = 'Account', Context_Field_API_Name_CC__c = 'Missing_Field__c'
            )
        };
        Boolean rejected = false;
        try {
            GuidancePathController_CC.getGuidanceData(account.Id);
        } catch (AuraHandledException expected) {
            rejected = true;
        }
        Assert.isTrue(rejected);
    }
}