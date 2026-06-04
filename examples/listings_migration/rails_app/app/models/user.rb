class User < ApplicationRecord
  has_many :agents, dependent: :restrict_with_error

  validates :email, presence: true, uniqueness: true
end
