/**
 * Test-only helper that gives the running System Administrator the record and field access the application code
 * needs when it queries or saves in user mode (WITH USER_MODE, AccessLevel.USER_MODE).
 *
 * In an org where this metadata is new (a fresh sandbox or the first production deployment), the System Administrator
 * profile has no access to the new custom fields, because profiles are not part of the deployment. The application
 * code then fails with errors such as "No such column" or "fields being inaccessible".
 *
 * grant() assigns the running user the four Carlton permission sets and a permission set created inside the test
 * that grants read (and, where the field can be written, edit) access to every field of the given objects. Both are
 * rolled back with the test, so nothing is left in the org.
 *
 * Usage: call grant() in @TestSetup or at the start of a test, then run the code under System.runAs(admin()) so the
 * new access is applied.
 */
@IsTest
public class TestAdminAccess_CC {

    public static final List<String> CARLTON_PERMISSION_SETS = new List<String>{
        'PS_System_Admin_Access', 'PS_Carlton_Sales_User_CC', 'PS_Carlton_Marketing_User_CC', 'PS_Carlton_Finance_User_CC'
    };

    /** The running user (the System Administrator who runs the deployment tests), for use with System.runAs. */
    public static User admin() {
        return new User(Id = UserInfo.getUserId());
    }

    /**
     * Gives the running user the four Carlton permission sets and full field access on the given objects.
     * Runs its setup DML in its own runAs block, so it can be called before or after test data is created.
     */
    public static void grant(List<SObjectType> objectTypes) {
        grant(objectTypes, new List<String>());
    }

    /**
     * As grant(objectTypes), plus further permission sets the code under test checks for (for example the custom
     * permission in Opportunity_UI2_Admin_CC that lets a user mark UI2 test records).
     */
    public static void grant(List<SObjectType> objectTypes, List<String> extraPermissionSets) {
        List<String> permissionSets = new List<String>(CARLTON_PERMISSION_SETS);
        permissionSets.addAll(extraPermissionSets);
        System.runAs(admin()) {
            assignPermissionSets(permissionSets);
            grantFieldAccess(objectTypes);
        }
    }

    private static void assignPermissionSets(List<String> permissionSets) {
        Id userId = UserInfo.getUserId();
        Set<Id> alreadyAssigned = new Set<Id>();
        for (PermissionSetAssignment existing : [SELECT PermissionSetId FROM PermissionSetAssignment
                                                 WHERE AssigneeId = :userId AND PermissionSet.Name IN :permissionSets]) {
            alreadyAssigned.add(existing.PermissionSetId);
        }
        List<PermissionSetAssignment> rows = new List<PermissionSetAssignment>();
        for (PermissionSet ps : [SELECT Id FROM PermissionSet WHERE Name IN :permissionSets]) {
            if (!alreadyAssigned.contains(ps.Id)) {
                rows.add(new PermissionSetAssignment(AssigneeId = userId, PermissionSetId = ps.Id));
            }
        }
        insert rows;
    }

    private static void grantFieldAccess(List<SObjectType> objectTypes) {
        PermissionSet access = new PermissionSet(
            Name = 'ZZ_Test_Admin_Access_' + String.valueOf(Math.abs(Crypto.getRandomInteger())).left(8),
            Label = 'ZZ Test Admin Access');
        insert access;

        List<ObjectPermissions> objectRows = new List<ObjectPermissions>();
        List<FieldPermissions> fieldRows = new List<FieldPermissions>();
        for (SObjectType objectType : objectTypes) {
            DescribeSObjectResult objectDescribe = objectType.getDescribe();
            String objectName = objectDescribe.getName();
            if (objectDescribe.isCustom()) {
                objectRows.add(new ObjectPermissions(ParentId = access.Id, SobjectType = objectName, PermissionsRead = true,
                    PermissionsCreate = true, PermissionsEdit = true, PermissionsDelete = true));
            }
            for (SObjectField field : objectDescribe.fields.getMap().values()) {
                DescribeFieldResult fieldDescribe = field.getDescribe();
                if (!fieldDescribe.isPermissionable()) {
                    continue;
                }
                Boolean writable = !fieldDescribe.isCalculated() && !fieldDescribe.isAutoNumber();
                fieldRows.add(new FieldPermissions(ParentId = access.Id, SobjectType = objectName,
                    Field = objectName + '.' + fieldDescribe.getName(), PermissionsRead = true, PermissionsEdit = writable));
            }
        }
        Database.insert(objectRows, false);

        // Some fields accept read access only (for example fields set by the system); grant those read-only.
        List<Database.SaveResult> results = Database.insert(fieldRows, false);
        List<FieldPermissions> readOnly = new List<FieldPermissions>();
        for (Integer i = 0; i < results.size(); i++) {
            if (!results[i].isSuccess() && fieldRows[i].PermissionsEdit) {
                FieldPermissions retry = fieldRows[i].clone(false, true);
                retry.PermissionsEdit = false;
                readOnly.add(retry);
            }
        }
        Database.insert(readOnly, false);

        insert new PermissionSetAssignment(AssigneeId = UserInfo.getUserId(), PermissionSetId = access.Id);
    }
}
