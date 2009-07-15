#require 'rubygems'
require 'dm-core'
require 'dm-serializer'
require 'dm-types'
require "google_spreadsheet"


DataMapper.setup(:default, 'sqlite3::memory:')

class GoogleSpreadsheetSource
  attr_reader :sheet, :num_rows

  def initialize(sheet_symbol)
    @email = "johnlester@gmail.com"
    @password = "jim1dogg"
    case sheet_symbol
    when :donne_data_units
      @key = "rzcPpo0eOybxpVJj6joDxFw"
      @sheet_number = 0
    else
      raise "Symbol passed in to argument does not correspond to a known data source"
    end
    @session = GoogleSpreadsheet.login(@email, @password)
    @sheet = @session.spreadsheet_by_key(@key).worksheets[@sheet_number]
    @headings = @sheet.rows[0]
    @num_rows = @sheet.num_rows
  end
  
  def cell(row, heading)    
    @sheet[row, @headings.index(heading) + 1]
  end
  
end

class CardUnit
  include DataMapper::Resource
  property :id,               Serial
  property :player,           Integer
  property :name,             String
  property :max_health,       Integer
  property :action,           Yaml
  property :defense,          Yaml
  property :battle_count,     Integer
  property :win_count,        Integer
  
  BASE_MAX_HEALTH = 1000
  BASE_ATTACK_DAMAGE = 50
   
  def self.populate_from_google
    source = GoogleSpreadsheetSource.new(:donne_data_units)
    (2..source.num_rows).each do |row|
      new_card = CardUnit.new
      new_card.name = source.cell(row, 'name')
      new_card.max_health = source.cell(row, 'max_health').to_f * BASE_MAX_HEALTH
      new_card.action = []
      new_card.action[0] = {:action_type => source.cell(row, 'action_0_type'), 
                            :target => source.cell(row, 'action_0_target'),
                            :amount => source.cell(row, 'action_0_amount')}
      new_card.defense = {}
      new_card.save
    end
  end

end

class BattleUnit
  include DataMapper::Resource
  property :id,               Serial
  property :player,           Integer
  property :name,             String
  property :current_health,   Integer
  property :max_health,       Integer
  property :action,           Yaml
  property :defense,          Yaml
  property :alive,            Boolean, :default => true
  
  def initialize(card_unit)
    # self.player = card_unit.player
    self.name = card_unit.name
    self.max_health = card_unit.max_health
    self.action = card_unit.action
    self.defense = card_unit.defense
    self.current_health = self.max_health
    self.save
  end
  
end


# class Player
#   include DataMapper::Resource
#   property :id,         Serial
#   
# end

class Battle
  include DataMapper::Resource
  property :id,         Serial  
  property :round,      Integer,    :default => 0
  
  has n, :players
  has n, :battle_units
  
  def targetable_units_of(player)
    self.battle_units.all(:alive => true, :player => player)
  end
  
  def target_of(battle_unit)
    if battle_unit.player = 1
      return targetable_units_of(2)[0]
    else
      return targetable_units_of(1)[0]
    end
  end
  
  def active_units
    
  end
  
end

class BattleTesting
  def initialize(options = {})
    options = {:trials => 1000, }.merge(options)
  end

  
  def prep_db
    DataMapper.auto_migrate!
    CardUnit.populate_from_google
  end
  
  def do_battle
    #create battle
    battle = Battle.new
    battle.save
    
    #pick teams of units and add to battle
    number_templates = CardUnit.all.size
    [1, 2].each do |player|
      2.times do
        bu = BattleUnit.new(CardUnit.get(rand(number_templates)))
        bu.update_attributes(:player => player)
        battle.battle_units << bu
      end
    end

    #run battle
    #store results
  end
  
end


