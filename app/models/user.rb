# == Schema Information
#
# Table name: users
#
#  id                     :integer          not null, primary key
#  fullname               :text
#  email                  :text
#  remember_token         :text
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#  password_digest        :text
#  scites_count           :integer          default(0)
#  password_reset_token   :text
#  password_reset_sent_at :datetime
#  confirmation_token     :text
#  active                 :boolean          default(FALSE)
#  comments_count         :integer          default(0)
#  confirmation_sent_at   :datetime
#  subscriptions_count    :integer          default(0)
#  expand_abstracts       :boolean          default(FALSE)
#  account_status         :text             default("user")
#  username               :text
#

class User < ActiveRecord::Base
  STATUS_ADMIN = 'admin'
  STATUS_MODERATOR = 'moderator'
  STATUS_USER = 'user'
  STATUS_SPAM = 'spam'
  ACCOUNT_STATES = [STATUS_ADMIN, STATUS_MODERATOR, STATUS_USER, STATUS_SPAM]

  has_secure_password

  has_many :scites, dependent: :destroy
  has_many :scited_papers, through: :scites, source: :paper
  has_many :comments, -> { order('created_at DESC') }, dependent: :destroy
  has_many :subscriptions, dependent: :destroy
  has_many :feeds, through: :subscriptions
  has_many :feed_preferences

  validates :fullname, presence: true, length: { maximum: 50 }

  valid_email_regex = /\A[\w+\-.]+@[a-z\d\-.]+\.[a-z]+\z/i
  validates :email, presence: true, format: { with: valid_email_regex },
                    uniqueness: { case_sensitive: false }

  valid_username_regex = /\A[a-zA-Z0-9_\.]+\z/i
  validates :username, presence: true, format: { with: valid_username_regex },
                    uniqueness: { case_sensitive: false }

  validates :password, length: { minimum: 6 }, on: :create

  acts_as_voter

  before_save do
    if new_record? || password_digest_changed? || email_changed?
      generate_token(:remember_token)
    end
  end

  # Tell Rails routes to use our username
  # instead of id in generating urls
  def to_param
    username
  end

  def self.find_by_username(username)
    User.where("lower(username) = ?", username.downcase).first
  end

  def scited?(paper)
    scites.find_by_paper_id(paper.id)
  end

  def scite!(paper)
    unless scites.find_by_paper_id(paper.id)
      scites.create!(paper_id: paper.id)
      paper.scites_count += 1
    end
  end

  def unscite!(paper)
    scites.find_by_paper_id(paper.id).destroy
    paper.scites_count -= 1
  end

  def subscribed?(feed)
    subscriptions.find_by_feed_id(feed.id)
  end

  def subscribe!(feed)
    subscriptions.create!(feed_id: feed.id)
  end

  def unsubscribe!(feed)
    subscriptions.find_by_feed_id(feed.id).destroy
  end

  def has_subscriptions?
    subscriptions.size > 0
  end

  def feed
    Paper.from_feeds_subscribed_by_cl(self)
  end

  def feed_without_cross_lists
    Paper.from_feeds_subscribed_by(self)
  end

  def feed_last_paper_date
    feed = feeds.where("last_paper_date IS NOT NULL").order("last_paper_date DESC").first
    feed && feed.last_paper_date.to_date
  end

  def send_signup_confirmation
    generate_token(:confirmation_token)
    save!
    UserMailer.signup_confirmation(self).deliver
  end

  def send_password_reset
    generate_token(:password_reset_token)
    save!
    UserMailer.password_reset(self).deliver
  end

  def clear_password_reset
    clear_token(:password_reset_token)
    save!
  end

  def send_email_change_confirmation(address)
    UserMailer.email_change(self, address).deliver
  end

  def active?
    active
  end

  def activate
    self.active = true
    clear_token(:confirmation_token)
    save!
  end

  def is_moderator?
    account_status == STATUS_MODERATOR || account_status == STATUS_ADMIN
  end

  def is_admin?
    account_status == STATUS_ADMIN
  end

  def is_spammer?
    account_status == STATUS_SPAM
  end

  def change_status(status)
    transaction do

      # Switching to/from spam needs propagation to comments
      if status == STATUS_SPAM
        self.comments.update_all(hidden: true)
      elsif account_status == STATUS_SPAM
        self.comments.update_all(hidden: false)
      end
      self.account_status = status
      self.save
    end
  end

  def change_password!(new_password)
    self.password = new_password
    self.password_confirmation = new_password
    UserMailer.password_change(self).deliver
    self.save!
  end

  # Data sent to the browser for JS interaction
  def to_js
    {
      fullname: self.fullname,
      email: self.email,
      expand_abstracts: self.expand_abstracts
    }.to_json
  end

  private
    # Generate a random confirmation token in column
    # Also puts the time in self[ column - '_token' + '_sent_at' ] if it exists
    def generate_token(column)
      self[column] = SecureRandom.urlsafe_base64

      column_split = column.to_s.split('_')

      if column_split[-1] == "token"
        sent_at = column_split[0..-2].append("sent_at").join('_').to_sym

        if User.column_names.include? sent_at.to_s
          self[sent_at] = Time.zone.now
        end
      end
    end

    # Clears a generated token
    # Also clears self[ column - '_token' + '_sent_at' ] if it exists
    def clear_token(column)
      self[column] = nil

      column_split = column.to_s.split
      if column_split[-1] == "token"
        sent_at = column_split[0..-2].append("sent_at").join('_').to_sym

        if User.column_names.include? sent_at.to_s
          self[sent_at] = nil
        end
      end
    end
end
