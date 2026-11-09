public final class PhoneNormalizer {
  private PhoneNormalizer() {}
  /** 숫자가 아닌 문자를 모두 제거한다. */
  public static String normalize(String phone) { return phone.replaceAll("[^0-9]", ""); }
}
