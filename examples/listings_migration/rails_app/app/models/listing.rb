class Listing < ApplicationRecord
  belongs_to :agent, optional: true

  validates :list_price,    presence: true,
                            numericality: { greater_than: 0 }
  validates :address_line1, presence: true
  validates :city,          presence: true
  validates :state_code,    presence: true, length: { is: 2 }
end
