package dalvik.annotation.compat;
public @interface UnsupportedAppUsage { int maxTargetSdk() default 0; String trackingBug() default ""; String expectedSignature() default ""; String implicitMember() default ""; String publicAlternatives() default ""; }
