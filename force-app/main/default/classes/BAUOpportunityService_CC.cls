public without sharing class BAUOpportunityService_CC {

    public static String bauId = Schema.SObjectType.Opportunity.getRecordTypeInfosByDeveloperName().get('BAU').getRecordTypeId();

    public static void createBAUOpportunities(List<Account> accounts) {

        Integer currentYear = Date.today().year();
        Integer currentMonth = Date.today().month();
        Set<Id> accountIds = new Set<Id>();

        for (Account account : accounts) {
            if (account.Is_BAU_Account_CC__c == true) {
                accountIds.add(account.Id);
            }
        }

        if (accountIds.isEmpty()) {
            return;
        }

        /*
         * Get existing BAU Opportunities for these Accounts
         * in the current year.
         */
        List<Opportunity> existingOpportunities = [
            SELECT Id, AccountId, CloseDate
            FROM Opportunity
            WHERE AccountId IN :accountIds
            AND BAU_Opportunity_CC__c = TRUE
            AND CloseDate >= :Date.newInstance(currentYear, 1, 1)
            AND CloseDate <= :Date.newInstance(currentYear, 12, 31)
        ];

        /*
         * Account + Year + Month
         *
         * Example:
         * AccountId-2026-09
         */
        Set<String> existingKeys = new Set<String>();
        for (Opportunity opportunity : existingOpportunities) {
            existingKeys.add(buildOpportunityKey(opportunity.AccountId, opportunity.CloseDate.year(), opportunity.CloseDate.month()));
        }

        List<Opportunity> opportunitiesToInsert = new List<Opportunity>();
        List<Account> accountsToUpdate = new List<Account>();

        for (Account account : accounts) {
            if (account.Is_BAU_Account_CC__c) {
                for (Integer month = currentMonth; month <= 12; month++) {
                    createOpportunity(account, currentYear, month, existingKeys, opportunitiesToInsert);
                }

                accountsToUpdate.add(new Account(Id = account.Id, Opportunity_Creation_Year_CC__c = String.valueOf(currentYear)));
            }
        }

        if (!opportunitiesToInsert.isEmpty()) {
            Database.insert(opportunitiesToInsert, AccessLevel.SYSTEM_MODE);
        }

        if (!accountsToUpdate.isEmpty()) {
            Database.update(accountsToUpdate, AccessLevel.SYSTEM_MODE);
        }
    }
    
    private static void createOpportunity(Account account, Integer year, Integer month, Set<String> existingKeys, List<Opportunity> opportunitiesToInsert) {
        String key = buildOpportunityKey(account.Id, year, month);

        if (!existingKeys.contains(key)) {
            Date firstDayOfMonth = Date.newInstance(year, month, 1);
            Date lastDayOfMonth = firstDayOfMonth.addMonths(1).addDays(-1);
            String monthName = getMonthName(month);
            String suffix = ' - BAU - ' + monthName + ' ' + String.valueOf(year);
            Integer maxAccountNameLength = 120 - suffix.length();
            String opportunityName = account.Name;

            if (opportunityName.length() > maxAccountNameLength) {
                opportunityName = opportunityName.substring(0, maxAccountNameLength);
            }

            Opportunity opportunity = new Opportunity(
                Name = opportunityName + suffix,
                RecordTypeId = bauId,
                AccountId = account.Id,
                OwnerId = account.OwnerId,
                CloseDate = lastDayOfMonth,
                BAU_Opportunity_CC__c = true,
                BAU_Month_CC__c = monthName,
                StageName = 'Request'
            );

            opportunitiesToInsert.add(opportunity);
            existingKeys.add(key);
        }

    }
    
    private static String getMonthName(Integer month) {
        List<String> monthNames = new List<String>{
            'January', 'February', 'March', 'April',
            'May', 'June', 'July', 'August',
            'September', 'October', 'November', 'December'
        };	
    
        return monthNames[month - 1];
    }

    private static String buildOpportunityKey(Id accountId, Integer year, Integer month) {
        return String.valueOf(accountId) + '-' + String.valueOf(year) + '-' + String.valueOf(month);
    }

    public static void closeExpiredBAUOpportunities(List<Opportunity> opportunities) {
        if (opportunities == null || opportunities.isEmpty()) {
            return;
        }

        for (Opportunity opportunity : opportunities) {
            opportunity.StageName = opportunity.RecordType.DeveloperName == 'New_Business' ? 'Closed Won' : 'Order';
        }

        update opportunities;
    }
}