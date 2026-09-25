import Foundation

enum APIError: LocalizedError {
    case invalidURL
    case socketNotConnected
    case socketSuspended
    case invalidResponse
    case serverError(String)
    case decodingError
    case encodingError
    case timeout

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Некорректный URL WebSocket"
        case .socketNotConnected:
            return "WebSocket не подключен"
        case .socketSuspended:
            return "Подключение WebSocket остановлено"
        case .invalidResponse:
            return "Некорректный ответ сервера"
        case .serverError(let message):
            return message
        case .decodingError:
            return "Ошибка декодирования ответа"
        case .encodingError:
            return "Ошибка кодирования запроса"
        case .timeout:
            return "Таймаут ожидания ответа"
        }
    }
}
