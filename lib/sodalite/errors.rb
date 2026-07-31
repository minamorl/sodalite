# frozen_string_literal: true

module Sodalite
  # Error responses are typed too. The shape a client sees when it gets it
  # wrong is declared in the same vocabulary as the shape it sees when it gets
  # it right, so "what does a 400 look like" has an answer you can read.
  module Errors
    SCHEMA = Zeolite.schema(
      error: { code: :string, message: :string },
      violations: [{ path: :string, code: :string, message: :string }]
    ).named(:Error)

    # Offered, not imposed. Pass it to `App.new(errors: ...)` if the vocabulary
    # fits; berylx error codes are yours, so the mapping is yours. Anything
    # unmapped is a 500, because an error the service never named is not one it
    # meant to expose.
    STATUS_BY_CODE = {
      invalid: 400,
      unauthorized: 401,
      forbidden: 403,
      not_found: 404,
      conflict: 409,
      gone: 410,
      unprocessable: 422,
      rate_limited: 429
    }.freeze

    module_function

    def body(code, message, violations = [])
      {
        error: { code: code.to_s, message: message.to_s },
        violations: violations.map do |violation|
          { path: violation.pointer, code: violation.code.to_s, message: violation.message }
        end
      }
    end
  end
end
