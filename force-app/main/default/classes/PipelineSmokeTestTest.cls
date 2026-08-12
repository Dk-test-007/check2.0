@isTest
private class PipelineSmokeTestTest {
  @isTest
  static void testPing() {
    System.assertEquals('pipeline ok', PipelineSmokeTest.ping());
  }
}
