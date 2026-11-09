public final class MaskingUtil {
  private MaskingUtil() {}
  public static String maskPhone(String phone) { return phone.substring(0, 3) + "****" + phone.substring(7); }
}
