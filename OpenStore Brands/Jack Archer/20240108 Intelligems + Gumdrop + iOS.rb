# ============================================================================
# Discount Campaigns Start
# ============================================================================

# Owner: OpenStore Revenue Team (#revenue-team)
# Description: special discount campaigns beyond those supported by Shopify;
#   e.g., to get around stacking limitations, or to support special combos.

class Campaign
    def initialize(condition, *qualifiers)
      @condition = (condition.to_s + '?').to_sym
      @qualifiers = PostCartAmountQualifier ? [] : [] rescue qualifiers.compact
      @line_item_selector = qualifiers.last unless @line_item_selector
      qualifiers.compact.each do |qualifier|
        is_multi_select = qualifier.instance_variable_get(:@conditions).is_a?(Array)
        if is_multi_select
          qualifier.instance_variable_get(:@conditions).each do |nested_q|
            @post_amount_qualifier = nested_q if nested_q.is_a?(PostCartAmountQualifier)
            @qualifiers << qualifier
          end
        else
          @post_amount_qualifier = qualifier if qualifier.is_a?(PostCartAmountQualifier)
          @qualifiers << qualifier
        end
      end if @qualifiers.empty?
    end
  
    def qualifies?(cart)
      return true if @qualifiers.empty?
      @unmodified_line_items = cart.line_items.map do |item|
        new_item = item.dup
        new_item.instance_variables.each do |var|
          val = item.instance_variable_get(var)
          new_item.instance_variable_set(var, val.dup) if val.respond_to?(:dup)
        end
        new_item
      end if @post_amount_qualifier
      @qualifiers.send(@condition) do |qualifier|
        is_selector = false
        if qualifier.is_a?(Selector) || qualifier.instance_variable_get(:@conditions).any? { |q| q.is_a?(Selector) }
          is_selector = true
        end rescue nil
        if is_selector
          raise "Missing line item match type" if @li_match_type.nil?
          cart.line_items.send(@li_match_type) { |item| qualifier.match?(item) }
        else
          qualifier.match?(cart, @line_item_selector)
        end
      end
    end
  
    def run_with_hooks(cart)
      before_run(cart) if respond_to?(:before_run)
      run(cart)
      after_run(cart)
    end
  
    def after_run(cart)
      @discount.apply_final_discount if @discount && @discount.respond_to?(:apply_final_discount)
      revert_changes(cart) unless @post_amount_qualifier.nil? || @post_amount_qualifier.match?(cart)
    end
  
    def revert_changes(cart)
      cart.instance_variable_set(:@line_items, @unmodified_line_items)
    end
  end
  
  class DiscountCodeList < Campaign
    def initialize(condition, customer_qualifier, cart_qualifier, line_item_selector, discount_list)
      super(condition, customer_qualifier, cart_qualifier)
      @line_item_selector = line_item_selector
      @discount_list = discount_list
    end
  
    def init_discount(type, amount, message)
      case type
      when :fixed
        return FixedTotalDiscount.new(amount, message, :split)
      when :percent
        return PercentageDiscount.new(amount, message)
      when :per_item
        return FixedItemDiscount.new(amount, message)
      end
    end
  
    def get_discount_code_type(discount_code)
      case discount_code
      when CartDiscount::Percentage
        return :percent
      when CartDiscount::FixedAmount
        return :fixed
      else
        return nil
      end
    end
  
    def run(cart)
      return unless cart.discount_code
      return unless qualifies?(cart)
  
      applied_code = cart.discount_code.code.downcase
      applicable_discount = @discount_list.select { |item| item[:code].downcase == applied_code }
      return if applicable_discount.empty?
      raise "#{applied_code} matches multiple discounts" if applicable_discount.length > 1
  
      applicable_discount = applicable_discount.first
      case applicable_discount[:type].downcase
      when 'p', 'percent'
        discount_type = :percent
      when 'f', 'fixed'
        discount_type = :fixed
      when 'per_item'
        discount_type = :per_item
      when 'c', 'code'
        discount_type = get_discount_code_type(cart.discount_code)
      end
      return if discount_type.nil?
  
      @discount = init_discount(discount_type, applicable_discount[:amount].to_f, applied_code)
      cart.line_items.each do |item|
        next unless @line_item_selector.nil? || @line_item_selector.match?(item)
        @discount.apply(item)
      end
    end
  end
  
  class ConditionalDiscount < Campaign
    def initialize(condition, customer_qualifier, cart_qualifier, line_item_selector, discount, max_discounts)
      super(condition, customer_qualifier, cart_qualifier)
      @line_item_selector = line_item_selector
      @discount = discount
      @items_to_discount = max_discounts == 0 ? nil : max_discounts
    end
  
    def run(cart)
      raise "Campaign requires a discount" unless @discount
      return unless qualifies?(cart)
      applicable_items = cart.line_items.select { |item| @line_item_selector.nil? || @line_item_selector.match?(item) }
      applicable_items = applicable_items.sort_by { |item| item.variant.price }
      applicable_items.each do |item|
        break if @items_to_discount == 0
        if (!@items_to_discount.nil? && item.quantity > @items_to_discount)
          new_item = item.split(take: item.quantity - @items_to_discount)
          @discount.apply(item)
          cart.line_items << new_item
          @items_to_discount = 0
        else
          @discount.apply(item)
          @items_to_discount -= item.quantity if !@items_to_discount.nil?
        end
      end
    end
  end
  
  class BuyXGetX < Campaign
    def initialize(condition, customer_qualifier, cart_qualifier, buy_item_selector, buy_x, get_item_selector, get_x, discount, max_sets)
      super(condition, customer_qualifier, cart_qualifier)
      @line_item_selector = buy_item_selector
      @get_item_selector = get_item_selector
      @discount = discount
      @buy_x = buy_x
      @get_x = get_x
      @max_sets = max_sets == 0 ? nil : max_sets
    end
  
    def run(cart)
      raise "Campaign requires a discount" unless @discount
      return unless qualifies?(cart)
      return unless cart.line_items.reduce(0) { |total, item| total += item.quantity } >= @buy_x
      applicable_buy_items = nil
      eligible_get_items = nil
      discountable_sets = 0
  
      # Find the items that qualify for buy_x
      if @line_item_selector.nil?
        applicable_buy_items = cart.line_items
      else
        applicable_buy_items = cart.line_items.select { |item| @line_item_selector.match?(item) }
      end
  
      # Find the items that qualify for get_x
      if @get_item_selector.nil?
        eligible_get_items = cart.line_items
      else
        eligible_get_items = cart.line_items.select { |item| @get_item_selector.match?(item) }
      end
  
      # Check if cart qualifies for discounts and limit the discount sets
      purchased_quantity = applicable_buy_items.reduce(0) { |total, item| total += item.quantity }
      discountable_sets = (@max_sets ? [purchased_quantity / @buy_x, @max_sets].min : purchased_quantity / @buy_x).to_i
      return if discountable_sets < 1
      discountable_quantity = (discountable_sets * @get_x).to_i
      # Apply the discounts (sort to discount lower priced items (with fewest discounts) first)
      eligible_get_items = eligible_get_items.sort_by { |item| [item.variant.price, -item.line_price.cents.to_s.to_i] }
      eligible_get_items.each do |item|
        break if discountable_quantity == 0
        if item.quantity <= discountable_quantity
          @discount.apply(item)
          discountable_quantity -= item.quantity
        else
          new_item = item.split({ take: item.quantity - discountable_quantity })
          @discount.apply(item)
          cart.line_items << new_item
          discountable_quantity = 0
        end
      end
    end
  end
  
  class BundleDiscount < Campaign
    def initialize(condition, customer_qualifier, cart_qualifier, bundle_products, discount)
      super(condition, customer_qualifier, cart_qualifier, nil)
      @bundle_products = bundle_products
      @discount = discount
    end
  
    def find_bundles(cart)
      bundle_parts = @bundle_products.map do |bitem|
        items = cart.line_items.select { |item| bitem[:selector].match?(item) }
        quantity_required = bitem[:quantity].to_i
        total_quantity = items.reduce(0) { |total, item| total + item.quantity }
        {
          items: items,
          quantity_required: quantity_required,
          total_possible: (total_quantity / quantity_required).to_i,
        }
      end
  
      max_bundles = bundle_parts.map{ |part| part[:total_possible] }.min
      return [] if max_bundles == 0
  
      qualified_items = []
      bundle_parts.each do |part|
        num_items_remaining = max_bundles * part[:quantity_required]
        part[:items].each do |item|
          break if num_items_remaining == 0
          if item.quantity > num_items_remaining
            new_item = item.split({take: item.quantity - num_items_remaining})
            cart.line_items << new_item
            qualified_items << item
            num_items_remaining = 0
          else
            qualified_items << item
            num_items_remaining -= item.quantity
          end
        end
      end
      qualified_items
    end
  
    def run(cart)
      raise "Campaign requires a discount" unless @discount
      return unless qualifies?(cart)
  
      eligible_items = find_bundles(cart)
      eligible_items.each { |item| @discount.apply(item) }
  
      # Insert bundle at the top of the cart.
      eligible_items.reverse.each do |item|
        cart.line_items.delete(item)
        cart.line_items.prepend(item)
      end
    end
  end
  
  class Qualifier
    def partial_match(match_type, item_info, possible_matches)
      match_type = (match_type.to_s + '?').to_sym
      if item_info.kind_of?(Array)
        possible_matches.any? do |possibility|
          item_info.any? do |search|
            search.send(match_type, possibility)
          end
        end
      else
        possible_matches.any? do |possibility|
          item_info.send(match_type, possibility)
        end
      end
    end
  
    def compare_amounts(compare, comparison_type, compare_to)
      case comparison_type
      when :greater_than
        return compare > compare_to
      when :greater_than_or_equal
        return compare >= compare_to
      when :less_than
        return compare < compare_to
      when :less_than_or_equal
        return compare <= compare_to
      when :equal_to
        return compare == compare_to
      else
        raise "Invalid comparison type"
      end
    end
  end
  
  class ExcludeDiscountCodes < Qualifier
    def initialize(behaviour, message, match_type = :reject_except, discount_codes = [])
      @reject = behaviour == :apply_script
      @message = message == "" ? "This coupon is valid for mobile application only." : message
      @match_type = match_type
      @discount_codes = discount_codes.map(&:downcase)
    end
  
    def match?(cart, selector = nil)
      return true if cart.discount_code.nil?
      return false if !@reject
      discount_code = cart.discount_code.code.downcase
  
      isIosCart = cart.line_items.any? { |line_item| 
        line_item.properties["_platform"] == "ios"
      }
  
      should_accept = false
      case @match_type
      when :reject_except
        # Accept only certain discount codes
        should_accept = @discount_codes.include?(discount_code)
      when :accept_except
        # Ban certain discount codes unless the cart is iOS
        if isIosCart == true
          should_accept = true
        else
          should_accept = !@discount_codes.include?(discount_code)
        end
      end
  
      if !should_accept
        cart.discount_code.reject({ message: @message })
      end
      return true
    end
  end
  
  class CartHasItemQualifier < Qualifier
    def initialize(quantity_or_subtotal, comparison_type, amount, item_selector)
      @quantity_or_subtotal = quantity_or_subtotal
      @comparison_type = comparison_type
      @amount = quantity_or_subtotal == :subtotal ? Money.new(cents: amount * 100) : amount
      @item_selector = item_selector
    end
  
    def match?(cart, selector = nil)
      raise "Must supply an item selector for the #{self.class}" if @item_selector.nil?
      case @quantity_or_subtotal
      when :quantity
        total = cart.line_items.reduce(0) do |total, item|
          total + (@item_selector&.match?(item) ? item.quantity : 0)
        end
      when :subtotal
        total = cart.line_items.reduce(Money.zero) do |total, item|
          total + (@item_selector&.match?(item) ? item.line_price : Money.zero)
        end
      end
      compare_amounts(total, @comparison_type, @amount)
    end
  end
  
  class CartQuantityQualifier < Qualifier
    def initialize(total_method, comparison_type, quantity)
      @total_method = total_method
      @comparison_type = comparison_type
      @quantity = quantity
    end
  
    def match?(cart, selector = nil)
      case @total_method
        when :item
          total = cart.line_items.reduce(0) do |total, item|
            total + ((selector ? selector.match?(item) : true) ? item.quantity : 0)
          end
        when :cart
          total = cart.line_items.reduce(0) { |total, item| total + item.quantity }
      end
      if @total_method == :line_any || @total_method == :line_all
        method = @total_method == :line_any ? :any? : :all?
        qualified_items = cart.line_items.select { |item| selector ? selector.match?(item) : true }
        qualified_items.send(method) { |item| compare_amounts(item.quantity, @comparison_type, @quantity) }
      else
        compare_amounts(total, @comparison_type, @quantity)
      end
    end
  end
  
  class Selector
    def partial_match(match_type, item_info, possible_matches)
      match_type = (match_type.to_s + '?').to_sym
      if item_info.kind_of?(Array)
        possible_matches.any? do |possibility|
          item_info.any? do |search|
            search.send(match_type, possibility)
          end
        end
      else
        possible_matches.any? do |possibility|
          item_info.send(match_type, possibility)
        end
      end
    end
  end
  
  class ProductTagSelector < Selector
    def initialize(match_type, match_condition, tags)
      @match_condition = match_condition
      @invert = match_type == :does_not
      @tags = tags.map(&:downcase)
    end
  
    def match?(line_item)
      product_tags = line_item.variant.product.tags.to_a.map(&:downcase)
      case @match_condition
      when :match
        return @invert ^ ((@tags & product_tags).length > 0)
      else
        return @invert ^ partial_match(@match_condition, product_tags, @tags)
      end
    end
  end
  
  class ProductIdSelector < Selector
    def initialize(match_type, product_ids)
      @invert = match_type == :not_one
      @product_ids = product_ids.map { |id| id.to_i }
    end
  
    def match?(line_item)
      @invert ^ @product_ids.include?(line_item.variant.product.id)
    end
  end
  
  class ItemMinPriceSelector < Selector
    def initialize(options = {})
      @min_price = Money.new(cents: options.fetch(:cents, 10000000))
    end
  
    def match?(line_item)
      line_item.line_price >= (@min_price * line_item.quantity)
    end
  end
  
  class LineItemPropertiesSelector < Selector
    def initialize(target_properties)
      @target_properties = target_properties
    end
  
    def match?(line_item)
      line_item_props = line_item.properties
      @target_properties.all? do |key, value|
        next unless line_item_props.has_key?(key)
        true if line_item_props[key].downcase == value.downcase
      end
    end
  end
  
  class ProductDiscountedSelector < Selector
    def initialize(discounted)
      @discounted = discounted
    end
  
    def match?(line_item)
      return @discounted == line_item.discounted?
    end
  end
  
  class AndSelector
    def initialize(*conditions)
      @conditions = conditions.compact
    end
  
    def match?(item, selector = nil)
      @conditions.all? do |condition|
        if selector
          condition.match?(item, selector)
        else
          condition.match?(item)
        end
      end
    end
  end
  
  class OrSelector
    def initialize(*conditions)
      @conditions = conditions.compact
    end
  
    def match?(item, selector = nil)
      @conditions.any? do |condition|
        if selector
          condition.match?(item, selector)
        else
          condition.match?(item)
        end
      end
    end
  end
  
  class NotSelector
    def initialize(condition)
      @condition = condition
    end
  
    def match?(item, selector = nil)
      if selector
        !@condition.match?(item, selector)
      else
        !@condition.match?(item)
      end
    end
  end
  
  class PercentageDiscount
    def initialize(percent, message)
      @discount = (100 - percent) / 100.0
      @message = message
    end
  
    def apply(line_item)
      line_item.change_line_price(line_item.line_price * @discount, message: @message)
    end
  end
  
  class FixedTotalDiscount
    def initialize(amount, message, behaviour = :to_zero)
      @amount = Money.new(cents: amount * 100)
      @message = message
      @discount_applied = Money.zero
      @all_items = []
      @is_split = behaviour == :split
    end
  
    def apply(line_item)
      if @is_split
        @all_items << line_item
      else
        return unless @discount_applied < @amount
        discount_to_apply = [(@amount - @discount_applied), line_item.line_price].min
        line_item.change_line_price(line_item.line_price - discount_to_apply, { message: @message })
        @discount_applied += discount_to_apply
      end
    end
  
    def apply_final_discount
      return if @all_items.length == 0
      total_items = @all_items.length
      total_quantity = 0
      total_cost = Money.zero
      @all_items.each do |item|
        total_quantity += item.quantity
        total_cost += item.line_price
      end
      @all_items.each_with_index do |item, index|
        discount_percent = item.line_price.cents / total_cost.cents
        if total_items == index + 1
          discount_to_apply = Money.new(cents: @amount.cents - @discount_applied.cents.floor)
        else
          discount_to_apply = Money.new(cents: @amount.cents * discount_percent)
        end
        item.change_line_price(item.line_price - discount_to_apply, { message: @message })
        @discount_applied += discount_to_apply
      end
    end
  end
  
  class FixedItemDiscount
    def initialize(amount, message)
      @amount = Money.new(cents: amount * 100)
      @message = message
    end
  
    def apply(line_item)
      per_item_price = line_item.variant.price
      per_item_discount = [(@amount - per_item_price), @amount].max
      discount_to_apply = [(per_item_discount * line_item.quantity), line_item.line_price].min
      line_item.change_line_price(line_item.line_price - discount_to_apply, { message: @message })
    end
  end
  
  class FixedFinalPriceDiscount
    def initialize(final_price, message, overrides = nil)
      @per_item_final_price = final_price# Money.new(cents: final_price * 100)
      @message = message
      @final_price_overrides = overrides || []
    end
  
    def apply(line_item)
      per_item_final_price = @final_price_overrides.reverse.reduce(@per_item_final_price) { |c, o| o[:selector].match?(line_item) ? o[:price] : c }
      final_price = Money.new(cents: per_item_final_price * 100) * line_item.quantity
      line_item.change_line_price(final_price, { message: @message }) if final_price < line_item.line_price
    end
  end
  
  # Jetsetter Pants (https://jackarcher.myshopify.com/admin/products?selectedView=all&product_type=Pants)
  SELECTOR_JETSETTER_PANTS = ProductIdSelector.new(:is_one, [
    "6817243365540", # Space Black @ $99
    "6817243496612", # Charcoal    @ $99
    "6817243725988", # Deep Blue   @ $99
    "6817243889828", # Stone       @ $117
    "7909754110168", # Olive Green @ $99
  ])
  
  # Legacy Jacket (https://admin.shopify.com/store/jackarcher/products?selectedView=all&product_type=Jacket)
  SELECTOR_LEGACY_JACKET = ProductIdSelector.new(:is_one, [
    "7932561096920", # Legacy Jacket @ $117
  ])
  
  # Jetsetter Boxer Briefs (https://jackarcher.myshopify.com/admin/products?selectedView=all&product_type=Underwear)
  SELECTOR_JETSETTER_BOXERS = ProductIdSelector.new(:is_one, [
    "6748415164580", # Mid   @ $30
    "6748416442532", # Long  @ $30
    "6748422733988", # Short @ $30
  ])
  
  # Jetsetter Boxer Briefs (https://jackarcher.myshopify.com/admin/products?selectedView=all&product_type=Underwear)
  SELECTOR_JETSETTER_BOXERS_ALL = ProductIdSelector.new(:is_one, [
    "6748415164580", # Mid   @ $30
    "6748416442532", # Long  @ $30
    "6748422733988", # Short @ $30
  ])
  
  # Jetsetter Anytime Tees (https://jackarcher.myshopify.com/admin/products?selectedView=all&product_type=T-Shirt)
  SELECTOR_ANYTIME_TEES = ProductIdSelector.new(:is_one, ["7827355500760"]) # @ $43
  
  # Selects line-items from the Weekender Bundle promotion (https://jackarcher.com/pages/build-your-own-bundle).
  # All items added from the bundle landing page have a special `_byoPage=true` property.
  SELECTOR_WEEKENDER_BUNDLE_ITEM = LineItemPropertiesSelector.new({"_byoPage" => "true"})
  
  # Select line-items with no discounts. Using this could potentially conflict with price testing.
  SELECTOR_UNDISCOUNTED = ProductDiscountedSelector.new(false)
  
  # N.B. The order of the discount campaigns in this list matters. Every
  # applicable discount will stack. Make sure you understand the existing
  # discounts before adding new ones.
  CAMPAIGNS = [
    # Disable App discount code on web.
    # Main assumption: "Storefront API channels" is unchecked for the script.
    DiscountCodeList.new(
      :all,
      nil,
      ExcludeDiscountCodes.new(
        :apply_script,
        "",
        :accept_except,
        ["APP20", "APP15"]
      ),
      nil,
      []
    ),
    # Weekender Bundle (https://jackarcher.com/pages/build-your-own-bundle):
    # Tee + Pants + Boxer for $149 (instead of $172).
    BundleDiscount.new(
      :all,
      nil,
      CartHasItemQualifier.new(:quantity, :greater_than_or_equal, 3, SELECTOR_WEEKENDER_BUNDLE_ITEM),
      [
        { :quantity => 1, :selector => AndSelector.new(SELECTOR_WEEKENDER_BUNDLE_ITEM, SELECTOR_ANYTIME_TEES) },
        { :quantity => 1, :selector => AndSelector.new(SELECTOR_WEEKENDER_BUNDLE_ITEM, SELECTOR_JETSETTER_BOXERS_ALL) },
        { :quantity => 1, :selector => AndSelector.new(SELECTOR_WEEKENDER_BUNDLE_ITEM, SELECTOR_JETSETTER_PANTS) },
      ],
      FixedFinalPriceDiscount.new(149.0, "Weekender Bundle", [
        { :price => 37.25, :selector => SELECTOR_ANYTIME_TEES },
        { :price => 26.00, :selector => SELECTOR_JETSETTER_BOXERS },
        { :price => 85.75, :selector => SELECTOR_JETSETTER_PANTS },
      ]),
    ),
    # "Buy Jetsetter Pants + Legacy Jacket for $50 off" promotion. Usually $198, now $148.
    BundleDiscount.new(
      :all,
      nil,
      nil,
      [
        { :quantity => 1, :selector => AndSelector.new(SELECTOR_JETSETTER_PANTS, SELECTOR_UNDISCOUNTED) },
        { :quantity => 1, :selector => AndSelector.new(SELECTOR_LEGACY_JACKET, SELECTOR_UNDISCOUNTED) },
      ],
      FixedFinalPriceDiscount.new(148.0, "BUNDLE", [
        { :price => 59.0, :selector => SELECTOR_JETSETTER_PANTS },
        { :price => 89.0, :selector => SELECTOR_LEGACY_JACKET },
      ]),
    ),
    # Volume discount on underwear: $100 for every 5 (compared to $150). Assumes
    # underwears are $30 each, so this translates to $10 off per pair.
    BuyXGetX.new(
      :all,
      nil,
      nil,
      AndSelector.new(SELECTOR_JETSETTER_BOXERS, ItemMinPriceSelector.new(cents: 3000)), 5, # Buy 5 underwear @ $30,
      AndSelector.new(SELECTOR_JETSETTER_BOXERS, ItemMinPriceSelector.new(cents: 3000)), 5, # get 5 underwear @ $30
      FixedFinalPriceDiscount.new(20.00, "DEAL"),                                           # discounted to $20 each.
      0 # no limit on number of sets redeemed
    ),
  ].freeze
  
  
  # ============================================================================
  # Intelligems Start
  # ============================================================================
  
  # Owner: Intelligems (#ext-os-intelligems)
  # Description: A/B testing for prices, shipping rates, and volume discounts.
  
  class Intelligems
    def initialize(discount_property = '_igp', allow_free = false)
      @volume_discount_property = '_igvd'
      @volume_discount_message_property = '_igvd_message'
      @depreciated_property = '_igLineItemDiscount'
      @discount_property = discount_property
      @allow_free = allow_free
    end
  
    def discount_product(line_item)
      ig_price = Money.new(cents: line_item.properties[@discount_property])
  
      discount = line_item.line_price - (ig_price * line_item.quantity)
      if discount > Money.zero
        if @allow_free or discount < line_item.line_price
          line_item.change_line_price(line_item.line_price - discount, message: 'Discount')
        end
     end
    end
  
    def depreciated_discount_product(line_item)
      discount = Money.new(cents: line_item.properties[@depreciated_property])
      discount *= line_item.quantity
  
      if @allow_free or discount < line_item.line_price
        line_item.change_line_price(line_item.line_price - discount, message: 'Intelligems')
      end
    end
  
    def volume_discount(line_item)
      discount = Money.new(cents: line_item.properties[@volume_discount_property])
      discount *= line_item.quantity
  
      if discount < line_item.line_price
        message = line_item.properties[@volume_discount_message_property]
        line_item.change_line_price(line_item.line_price - discount, message: message)
      end
    end
  
    def run(cart)
      cart.line_items.each do |line_item|
        # line_item.change_properties({'_igp' => '200'}, message: "hi")
        if !line_item.properties[@discount_property].nil? && !line_item.properties[@discount_property].empty?
          discount_product(line_item)
        elsif !line_item.properties[@volume_discount_property].nil? && !line_item.properties[@volume_discount_property].empty?
          volume_discount(line_item)
        elsif !line_item.properties[@depreciated_property].nil? && !line_item.properties[@depreciated_property].empty?
          depreciated_discount_product(line_item)
        end
      end
    end
  end
  
  intelligems = Intelligems.new()
  intelligems.run(Input.cart)
  
  # Campaigns are executed here, to make sure discounts there use the "correct"
  # prices set by Intelligems tests.
  CAMPAIGNS.each do |campaign|
    campaign.run_with_hooks(Input.cart)
  end
  
  ##############################
  # GumdropLineItems Start
  ##############################
  class GumdropLineItems
    # Owner: OpenStore Unlock Team
    # Version: 2022-12-15
    # Description: The purpose of this script is to discount the Route protection package for
    #   customers who have a 100% off Gumdrop discount
    GUMDROP_FREE_SHIPPING_COUPON_PREFIX = 'GD-FS-'
  
    def self.run(cart)
      cart_discount = cart.discount_code
      return unless cart_discount
      return if cart_discount.rejected?
      return unless cart_discount.code.start_with?(GumdropLineItems::GUMDROP_FREE_SHIPPING_COUPON_PREFIX)
  
      cart.line_items.each do |line_item|
        product = line_item.variant.product
        if product.vendor == 'Route' && product.product_type == 'Insurance'
          line_item.change_line_price(Money.zero, message: 'Gumdrop Discount')
        end
      end
    end
  end
  
  GumdropLineItems.run(Input.cart)
  ##############################
  # GumdropLineItems End
  ##############################
  
  Output.cart = Input.cart
  