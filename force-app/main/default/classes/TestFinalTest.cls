@isTest
private class TestFinalTest {
  @isTest
  static void testConstructor() {
    TestFinal instance = new TestFinal();
    System.assertNotEquals(null, instance);
  }
}
