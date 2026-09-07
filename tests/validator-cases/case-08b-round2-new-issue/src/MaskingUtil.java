public final class MaskingUtil {
  private MaskingUtil() {}
  public static String maskPhone(String phone) {
    if (phone.length() < 8) return phone;
    return phone.substring(0, 3) + "****" + phone.substring(7);
  }
}
