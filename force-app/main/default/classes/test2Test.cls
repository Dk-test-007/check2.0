@isTest
private class test2Test {
  @isTest
  static void testConstructor() {
    test2 instance = new test2();
    System.assertNotEquals(null, instance);
  }
}
