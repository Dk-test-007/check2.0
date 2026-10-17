/**
 * =============================================================================
 * Class Name    : Logger_CC
 * Description   : Loggr framework
 *
 * Author        : Vansh Mansotra
 * Created Date  :
 *
 * =============================================================================
 * Modification History
 * =============================================================================
 * Version    Date         Author           Description
 * -------    ----------   ------------     ---------------------------------------
 *    1                    Vansh Mansotra   Initial setup for Logger
 *
 * =============================================================================
 * Usage:
 *   Apex / Trigger / Batch   ->  Logger.log(...)
 *   Flow / Process Builder   ->  "Publish Log" invocable action
 *   LWC / Aura               ->  Logger.logFromComponent(...)
 * =============================================================================
 */

public inherited sharing class Logger_CC {

    // Plain Strings so the same values work from Apex, Flow and LWC.
    public static final String INFO    = 'INFO';
    public static final String SUCCESS = 'SUCCESS';
    public static final String ERROR   = 'ERROR';

    public class LoggerException extends Exception {}

    private static final Integer MAX_TEXT = 255;

    // A platform event message cannot exceed 1 MB. Capping long fields at 30k keeps a fully
    // populated event well inside that ceiling.
    private static final Integer MAX_LONG = 30000;

    private static final Set<String> LEVELS = new Set<String>{
        'INFO', 'SUCCESS', 'ERROR'
    };

    // Source_Type__c is a restricted picklist on Logger__c, so anything unrecognised is
    // mapped to Other rather than failing the insert inside the subscriber.
    private static final Map<String, String> SOURCE_TYPES = new Map<String, String>{
        'APEX' => 'Apex', 'TRIGGER' => 'Trigger', 'BATCH' => 'Batch', 'FLOW' => 'Flow',
        'LWC' => 'LWC', 'AURA' => 'LWC', 'INTEGRATION' => 'Integration', 'OTHER' => 'Other'
    };

    private static final String TRANSACTION_ID = Request.getCurrent().getRequestId();
    private static final String QUIDDITY = String.valueOf(Request.getCurrent().getQuiddity());

    /** Carrier for a single log. Doubles as the Flow input, so there is one shape to learn. */
    public class LogInput {
        @InvocableVariable(label='Log Level' description='INFO, SUCCESS, or ERROR' required=true)
        public String level;
        @InvocableVariable(label='Message' required=true)
        public String message;
        @InvocableVariable(label='Source Type' description='Apex, Trigger, Batch, Flow, LWC, Integration or Other')
        public String sourceType;
        @InvocableVariable(label='Source Class' description='Class, trigger, Flow or component name')
        public String sourceClass;
        @InvocableVariable(label='Origin Location' description='Leave blank in Apex - derived from the stack trace')
        public String originLocation;
        @InvocableVariable(label='Related Record Ids' description='Semicolon separated')
        public String relatedRecordIds;
        @InvocableVariable(label='Integration Name')
        public String integrationName;
        @InvocableVariable(label='Comments')
        public String comments;
        public LogInput() {}
        public LogInput(String level, String message) {
            this.level = level;
            this.message = message;
        }
    }

    // ===================================================================== Apex entry points
    public static void log(String level, String message) {
        log(new LogInput(level, message));
    }
    public static void log(String level, String message, String comments) {
        LogInput input = new LogInput(level, message);
        input.comments = comments;
        log(input);
    }
    public static void log(String level, String message, Exception ex) {
        log(fromException(level, message, ex, null));
    }
    public static void log(String level, String message, List<Id> recordIds) {
        LogInput input = new LogInput(level, message);
        input.relatedRecordIds = joinIds(recordIds);
        log(input);
    }
    public static void log(String level, String message, Exception ex, List<Id> recordIds) {
        log(fromException(level, message, ex, recordIds));
    }
    public static void log(Exception ex) {
        log(fromException(ERROR, ex == null ? 'Unknown exception' : ex.getMessage(), ex, null));
    }

    /** Full control. */
    public static void log(LogInput input) {
        if (input == null) {
            return;
        }
        log(new List<LogInput>{ input });
    }

    /**
     * Bulk entry point. Each publish costs one DML statement out of 150, so if you are logging
     * inside a loop, collect LogInputs and pass them here rather than calling log() N times.
     */
    public static void log(List<LogInput> inputs) {
        if (inputs == null || inputs.isEmpty() || !isEnabled()) {
            return;
        }
        String origin = inferOrigin();
        List<Logger_Event_CC__e> events = new List<Logger_Event_CC__e>();
        for (LogInput input : inputs) {
            if (input == null) {
                continue;
            }
            events.add(toEvent(input, origin));
        }
        if (events.isEmpty()) {
            return;
        }
        for (Database.SaveResult result : EventBus.publish(events)) {
            if (!result.isSuccess()) {
                for (Database.Error err : result.getErrors()) {
                    // Nothing else to do - we cannot log the failure of the logger.
                    System.debug(LoggingLevel.ERROR, 'Logger: publish failed - ' + err.getMessage());
                }
            }
        }
    }

    // ===================================================================== Flow entry point
    @InvocableMethod(label='Publish Log' description='Writes a record to the Logger object via a platform event' category='Logging')
    public static void logFromFlow(List<LogInput> inputs) {
        if (inputs == null) {
            return;
        }
        for (LogInput input : inputs) {
            if (input != null && String.isBlank(input.sourceType)) {
                input.sourceType = 'Flow';
            }
        }
        log(inputs);
    }

    // ===================================================================== LWC / Aura entry point
    @AuraEnabled
    public static void logFromComponent(String level, String message, String sourceClass, String relatedRecordIds, String comments) {
        LogInput input = new LogInput(level, message);
        input.sourceType = 'LWC';
        input.sourceClass = sourceClass;
        input.relatedRecordIds = relatedRecordIds;
        input.comments = comments;
        log(input);
    }

    // ===================================================================== Internals
    private static Logger_Event_CC__e toEvent(LogInput input, String origin) {
        String location = String.isNotBlank(input.originLocation) ? input.originLocation : origin;
        String sourceType = String.isNotBlank(input.sourceType) ? input.sourceType : (String.isNotBlank(input.integrationName) ? 'Integration' : defaultSourceType(location));
        Logger_Event_CC__e e = new Logger_Event_CC__e(
            Log_Level_CC__c          = normalizeLevel(input.level),
            Message_CC__c            = truncate(input.message, MAX_LONG),
            Source_Type_CC__c        = normalizeSourceType(sourceType),
            Origin_Location_CC__c    = truncate(location, MAX_TEXT),
            Transaction_Id_CC__c     = TRANSACTION_ID,
            Related_Record_Ids_CC__c = truncate(input.relatedRecordIds, MAX_LONG),
            Integration_Name_CC__c   = truncate(input.integrationName, MAX_TEXT),
            Comments_CC__c           = truncate(input.comments, MAX_LONG)
        );
        e.Source_Class_CC__c = String.isNotBlank(input.sourceClass) ? truncate(input.sourceClass, MAX_TEXT) : classFrom(location);
        return e;
    }

    private static LogInput fromException(String level, String message, Exception ex, List<Id> recordIds) {
        LogInput input = new LogInput(level, message);
        input.relatedRecordIds = joinIds(recordIds);
        if (ex == null) {
            return input;
        }
        if (String.isBlank(input.message)) {
            input.message = ex.getMessage();
        }
        String detail = ex.getTypeName() + ': ' + ex.getMessage()
            + '\nLine ' + ex.getLineNumber()
            + '\n' + ex.getStackTraceString();
        Exception cause = ex.getCause();
        if (cause != null) {
            detail += '\nCaused by ' + cause.getTypeName() + ': ' + cause.getMessage()
                + '\n' + cause.getStackTraceString();
        }
        input.comments = String.isBlank(input.comments) ? detail : input.comments + '\n\n' + detail;
        return input;
    }

    /**
     * Throws and catches a private exception to read the current stack, then returns the first
     * frame outside this class. That is how Source_Class__c and Origin_Location__c get filled
     * without the caller passing anything.
     */
    private static String inferOrigin() {
        String stack;
        try {
            throw new LoggerException('origin probe');
        } catch (LoggerException probe) {
            stack = probe.getStackTraceString();
        }
        if (String.isBlank(stack)) {
            return null;
        }
        for (String line : stack.split('\n')) {
            String frame = line.trim();
            if (String.isBlank(frame)) {
                continue;
            }
            // Trailing dot matters: "Class.LoggerTest..." must not be skipped.
            if (frame.startsWith('Class.Logger.') || frame.startsWith('Class.Logger:')) {
                continue;
            }
            return frame;
        }
        return null;
    }

    /** "Class.OrderService.sync: line 42, column 1" -> "OrderService" */
    private static String classFrom(String location) {
        if (String.isBlank(location)) {
            return null;
        }
        String head = location.substringBefore(':');
        if (head.startsWith('Class.')) {
            String path = head.removeStart('Class.');
            return truncate(path.contains('.') ? path.substringBeforeLast('.') : path, MAX_TEXT);
        }
        if (head.startsWith('Trigger.')) {
            return truncate(head.removeStart('Trigger.'), MAX_TEXT);
        }
        return truncate(head, MAX_TEXT);
    }

    private static String defaultSourceType(String location) {
        if (String.isNotBlank(location) && location.trim().startsWith('Trigger.')) {
            return 'Trigger';
        }
        if (String.isBlank(QUIDDITY)) {
            return 'Apex';
        }
        if (QUIDDITY.startsWith('BATCH')) {
            return 'Batch';
        }
        if (QUIDDITY == 'AURA' || QUIDDITY == 'REMOTE_ACTION') {
            return 'LWC';
        }
        if (QUIDDITY == 'INVOCABLE_ACTION') {
            return 'Flow';
        }
        if (QUIDDITY == 'REST' || QUIDDITY == 'SOAP' || QUIDDITY == 'BULK_API') {
            return 'Integration';
        }
        return 'Apex';
    }

    private static String joinIds(List<Id> recordIds) {
        if (recordIds == null || recordIds.isEmpty()) {
            return null;
        }
        List<String> parts = new List<String>();
        for (Id recordId : recordIds) {
            if (recordId != null) {
                parts.add(String.valueOf(recordId));
            }
        }
        return parts.isEmpty() ? null : String.join(parts, ';');
    }

    private static String normalizeLevel(String level) {
        if (String.isBlank(level)) {
            return INFO;
        }
        String upper = level.trim().toUpperCase();
        if (upper == 'DEBUG') {
            upper = INFO;
        }
        if (upper == 'WARNING') {
            upper = ERROR;
        }
        if (upper == 'FATAL') {
            upper = ERROR;
        }
        return LEVELS.contains(upper) ? upper : INFO;
    }

    private static String normalizeSourceType(String sourceType) {
        if (String.isBlank(sourceType)) {
            return 'Apex';
        }
        String key = sourceType.trim().toUpperCase();
        return SOURCE_TYPES.containsKey(key) ? SOURCE_TYPES.get(key) : 'Other';
    }

    // -------------------------------------------------- configuration (custom metadata)

    @TestVisible
    private static Logger_Config_CC__mdt CONFIG {
        get {
            if (CONFIG == null) {
                CONFIG = Logger_Config_CC__mdt.getInstance('Default');
                if (CONFIG == null) {
                    // Fail open: a missing config record must not silence logging.
                    CONFIG = new Logger_Config_CC__mdt(Is_Enabled_CC__c = true);
                }
            }
            return CONFIG;
        }
        set;
    }

    private static Boolean isEnabled() {
        return CONFIG.Is_Enabled_CC__c != false;
    }

    private static String truncate(String value, Integer maxLength) {
        if (String.isBlank(value) || value.length() <= maxLength) {
            return value;
        }
        return value.abbreviate(maxLength);
    }
}