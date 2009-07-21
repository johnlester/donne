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
  property :actions,          Yaml, :default => []
  property :defense,          Yaml, :default => {}
  property :battle_count,     Integer, :default => 0
  property :win_count,        Integer, :default => 0
  
  belongs_to :player
  has n, :battle_units
  
  BASE_MAX_HEALTH = 1000
  BASE_ATTACK_DAMAGE = 50
   
  def self.populate_from_google
    source = GoogleSpreadsheetSource.new(:donne_data_units)
    (2..source.num_rows).each do |row|
      new_card = CardUnit.new
      new_card.name = source.cell(row, 'name')
      new_card.max_health = (source.cell(row, 'max_health').to_f * BASE_MAX_HEALTH).to_i
      new_card.actions[0] = {:action_type => source.cell(row, 'action_0_type').to_sym, 
                            :target_type => source.cell(row, 'action_0_target').to_sym,
                            :amount => (source.cell(row, 'action_0_amount').to_f * BASE_ATTACK_DAMAGE).to_i}
      new_card.save
    end
  end

  def win_percentage
    self.win_count.to_f / self.battle_count
  end

end

class BattleUnit
  include DataMapper::Resource
  property :id,               Serial
  property :player,           Integer
  property :name,             String
  property :current_health,   Integer
  property :max_health,       Integer
  property :actions,          Yaml
  property :defense,          Yaml                      # linear reductions in damage taken, by type
  property :alive,            Boolean, :default => true
  property :status_effects,   Yaml, :default => {}

  belongs_to :player
  belongs_to :battle
  belongs_to :card_unit
  
  def initialize(card_unit)
    # self.player = card_unit.player
    unless card_unit
      raise "nil card"
    end
    self.name = card_unit.name
    self.max_health = card_unit.max_health
    self.actions = card_unit.actions
    self.defense = card_unit.defense
    self.current_health = self.max_health
    self.card_unit = card_unit
    self.save
  end

  def receive_action(action)
    change_in_health = 0
    status_effect_changes = {}
    case action.action_type
    when :physical, :fire, :cold
      change_in_health =  - action.amount
    end 
    self.current_health = [self.current_health + change_in_health, self.max_health].min
    self.save
  end  

  def action_in_round(round)
    current_action = self.actions #needed to avoid nil error on reloaded YAML attribute 
    current_action = self.actions[round % (self.actions.size)]
    round_action = RoundAction.new
    round_action.origin = self
    round_action.target_type = current_action[:target_type]
    round_action.action_type = current_action[:action_type]    
    round_action.amount = current_action[:amount]
    return round_action
  end
  
  def round_end_activity
    if self.current_health <= 0
      self.alive = false
      self.save
    end
  end
  
end

class RoundAction
  attr_accessor :origin, :target_type, :action_type, :amount  
end

class Player
  include DataMapper::Resource
  property :id,         Serial
  
  has n, :battles, :through => Resource
  has n, :battle_units
  
end

class Battle
  include DataMapper::Resource
  property :id,         Serial  
  property :round,      Integer,    :default => 0
  property :outcome,     Integer,    :default => nil
  
  has n, :players, :through => Resource
  has n, :battle_units
  
  def do_battle
    while not battle_done?
      do_round
    end
    self.outcome = winning_player.id
    self.save
    return self.outcome
  end
  
  def targets_of(battle_unit, target_type)
    case target_type
    when :enemy
      return [self.battle_units.first(:alive => true, :player_id.not => battle_unit.player.id)]
    when :enemies
      return self.battle_units.all(:alive => true, :player_id.not => battle_unit.player.id)
    end
  end
  
  # units who get a turn, in order of actions
  def active_units
    self.battle_units.all(:alive => true)
  end
  
  
  def do_round
    active_units.each do |battle_unit|
      action = battle_unit.action_in_round(self.round)
      targets = targets_of(battle_unit, action.target_type)
      targets.each do |target|
        target.receive_action(action)
      end
    end
    round_end
  end
  
  def round_end
    self.battle_units.each do |battle_unit|
      battle_unit.round_end_activity
    end
    self.round += 1
    self.battle_units.reload
    self.save
  end
  
  def winning_player
    #count up living units each player has
    number_left = []
    self.players.each do |player|
      number_left << [player, units_left(player)]
    end
    return number_left.sort {|a,b| a[1] <=> b[1]}[0][0]
  end

  def units_left(player)
    self.battle_units.all(:alive => true, :player_id => player.id).size
  end

  def battle_done?
    case dead_players
    when 0
      return false
    else
      return true
    end
  end
  
  def dead_players
    result = 0
    self.players.each do |player|
      result += 1 if units_left(player) == 0 
    end
    return result
  end
  
end

class BattleTesting
  def initialize(options = {})
    options = {:count => 100}.merge!(options)
    report_interval = options[:count] / 10
    prep_db
    options[:count].times do |i|
      do_battle
      puts i #if (i % report_interval) == 0
    end    
  end
  
  def prep_db
    DataMapper.auto_migrate!
    CardUnit.populate_from_google
    create_test_players
  end
  
  def create_test_players
    @test_players = []
    @test_players[0] = Player.create
    @test_players[1] = Player.create
  end
  
  def do_battle
    repository do
    
      #create battle
      battle = Battle.new
      battle.save

      #add players to battle    
      #pick teams of units and add to battle
      number_templates = CardUnit.all.size
      @test_players.each do |player|
        battle.players << player
        2.times do
          bu = BattleUnit.new(CardUnit.get(1 + rand(number_templates - 1)))
          bu.update_attributes(:player => player)
          battle.battle_units << bu
        end
      end
      battle.save

      #run battle
      outcome = battle.do_battle

      #store results
      battle.battle_units.each do |battle_unit|
        card = battle_unit.card_unit
        card.battle_count += 1
        card.win_count += 1 if battle.outcome == battle_unit.player.id
        card.save
      end
    end #repository
  end
  
end


