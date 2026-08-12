/**
 * Minimal smoke-test class used to validate the dev -> qa -> uat -> main
 * CI/CD promotion pipeline end to end.
 */
public with sharing class PipelineSmokeTest {
  public static String ping() {
    return 'pipeline ok';
  }
}
