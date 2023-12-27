# ================================ Customizable Settings ================================
# ================================================================
# Tiered Discounts by Spend Threshold
#
# If the cart total is greater than (or equal to) an entered
# threshold, the associated discount is applied to each item.
#
#   - 'threshold' is the spend amount needed to qualify
#   - 'discount_type' is the type of discount to provide. Can be
#     either:
#       - ':percent'
#       - ':dollar'
#   - 'discount_amount' is the percentage/dollar discount to
#     apply (per item)
#   - 'discount_message' is the message to show when a discount
#     is applied
# ================================================================

SPENDING_THRESHOLDS_STANDARD = [
  {
    threshold: 150,
    discount_type: :dollar,
    discount_amount: 50,
    discount_message: 'Spend $150 and get $30 off!',
  },
]

SPENDING_THRESHOLDS_AMBASSADOR = [
  {
    threshold: 200,
    discount_type: :dollar,
    discount_amount: 50,
    discount_message: 'Spend $200 and get $50 off!',
  },
]

DISCOUNT_CODES = {
  '$30OFF' => SPENDING_THRESHOLDS_STANDARD,
  '$50OFF' => SPENDING_THRESHOLDS_AMBASSADOR
}

# ================================ Script Code (do not edit) ================================
# ================================================================
# DiscountApplicator
#
# Applies the entered discount to the supplied line item.
# ================================================================
class DiscountApplicator
  def initialize(discount_type, discount_amount, discount_message)
    @discount_type = discount_type
    @discount_message = discount_message

    @discount_amount = if discount_type == :percent
      1 - (discount_amount * 0.01)
    else
      Money.new(cents: 100) * discount_amount
    end
  end

  def apply(line_item)
    new_line_price = if @discount_type == :percent
      line_item.line_price * @discount_amount
    else
      [line_item.line_price - (@discount_amount * line_item.quantity), Money.zero].max
    end

    line_item.change_line_price(new_line_price, message: @discount_message)
  end
end

# ================================================================
# TieredDiscountBySpendCampaign
#
# If the cart total is greater than (or equal to) an entered
# threshold, the associated discount is applied to each item.
# ================================================================
class TieredDiscountBySpendCampaign
  def initialize(tiers)
    @tiers = tiers.sort_by { |tier| tier[:threshold] }.reverse
  end

  def run(cart)
    applicable_tier = @tiers.find { |tier| cart.subtotal_price >= (Money.new(cents: 100) * tier[:threshold]) }
    return if applicable_tier.nil?

    discount_applicator = DiscountApplicator.new(
      applicable_tier[:discount_type],
      applicable_tier[:discount_amount],
      applicable_tier[:discount_message]
    )

    cart.line_items.each do |line_item|
      next if line_item.variant.product.gift_card?
      discount_applicator.apply(line_item)
    end
  end
end

def discount_code_present(cart, code)
  !cart.discount_code.nil? and (cart.discount_code.code.upcase == code.upcase)
end

CAMPAIGNS = []

DISCOUNT_CODES.each do |discount_code|
  if discount_code_present(Input.cart, discount_code[0])
    CAMPAIGNS = [
      TieredDiscountBySpendCampaign.new(discount_code[1]),
    ]
  end
end

CAMPAIGNS.each do |campaign|
  campaign.run(Input.cart)
end

Output.cart = Input.cart