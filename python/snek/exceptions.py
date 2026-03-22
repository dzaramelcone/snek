"""snek.exceptions — HTTP exception classes.

Each exception maps to an HTTP status code. Raise from handlers
or middleware to short-circuit into an error response:

    raise NotFound("User not found")    # -> 404
    raise BadRequest("Invalid email")   # -> 400
"""

from __future__ import annotations


class SnekError(Exception):
    """Base class for all snek HTTP exceptions."""

    status_code: int = 500
    detail: str = "Internal Server Error"

    def __init__(self, detail: str | None = None) -> None:
        self.detail = detail or self.__class__.detail
        super().__init__(self.detail)


class BadRequest(SnekError):
    status_code: int = 400
    detail: str = "Bad Request"


class Unauthorized(SnekError):
    status_code: int = 401
    detail: str = "Unauthorized"


class Forbidden(SnekError):
    status_code: int = 403
    detail: str = "Forbidden"


class NotFound(SnekError):
    status_code: int = 404
    detail: str = "Not Found"


class MethodNotAllowed(SnekError):
    status_code: int = 405
    detail: str = "Method Not Allowed"


class Conflict(SnekError):
    status_code: int = 409
    detail: str = "Conflict"


class Gone(SnekError):
    status_code: int = 410
    detail: str = "Gone"


class UnprocessableEntity(SnekError):
    status_code: int = 422
    detail: str = "Unprocessable Entity"


class TooManyRequests(SnekError):
    status_code: int = 429
    detail: str = "Too Many Requests"


class InternalServerError(SnekError):
    status_code: int = 500
    detail: str = "Internal Server Error"
