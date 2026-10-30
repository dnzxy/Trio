extension Settings {
    final class Provider: BaseProvider, SettingsProvider {
        @Injected() var tidepoolManager: TidepoolManager!
        @Injected() var glookoManager: GlookoManager!
    }
}
