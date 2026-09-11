import AppKit
import CoreVideo
import SlovoCore

/// Захоплення екрана з боку стану програми: увімкнути, вимкнути і пустити
/// кадри тією самою дорогою, що й кадри фільму.
///
/// Тут навмисно немає нічого свого: ні окремого вікна на проекторі, ні
/// окремої дороги в мережу. Кадр віддається плеєру, а далі все вже
/// написане — зал, NDI, живий екран, указка, «Сховати» і затемнення.
extension AppState {

    /// Модель захоплення. Тримається окремо і заводиться першим зверненням.
    var screenCapture: ScreenCaptureModel {
        if let ready = screenCaptureStorage as? ScreenCaptureModel { return ready }
        let fresh = ScreenCaptureModel()
        fresh.onFrame = { [weak self] buffer in
            MainActor.assumeIsolated { self?.media.showCapturedFrame(buffer) }
        }
        // Плеєр сам знімає захоплення, коли в зал показують щось інше:
        // картинку, сторінку показу, фільм. Зупинити при цьому треба й самий
        // потік, інакше він далі гріє машину і тримає позначку запису екрана.
        media.stopCaptureStream = { [weak fresh] in fresh?.stop() }
        screenCaptureStorage = fresh
        return fresh
    }

    /// Почати показ монітора або вікна.
    func showCapturedScreen(_ source: ScreenCaptureModel.Source) {
        let capture = screenCapture
        media.beginCapture(title: source.title)
        guard capture.start(source) else {
            media.endCapture()
            return
        }
        // Показ у залі вмикається так само, як для картинки: людина натиснула
        // «Показати» — значить показати.
        isLive = true
        refreshSlide()
    }

    /// Зупинити показ екрана.
    func stopCapturedScreen() {
        screenCapture.stop()
        media.endCapture()
        refreshSlide()
    }
}
