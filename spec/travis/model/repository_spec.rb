require 'spec_helper'

describe Repository do
  include Support::ActiveRecord

  describe '#regenerate_key!' do
    it 'regenerates key' do
      repo = Factory(:repository)

      expect { repo.regenerate_key! }.to change { repo.key.private_key }
    end
  end

  describe 'validates' do
    it 'uniqueness of :owner_name/:name' do
      existing = Factory(:repository)
      repo = Repository.new(existing.attributes)
      repo.should_not be_valid
      repo.errors['name'].should == ['has already been taken']
    end
  end

  describe 'associations' do
    describe 'owner' do
      let(:user) { Factory(:user) }
      let(:org)  { Factory(:org)  }

      it 'can be a user' do
        repo = Factory(:repository, owner: user)
        repo.reload.owner.should == user
      end

      it 'can be an organization' do
        repo = Factory(:repository, owner: org)
        repo.reload.owner.should == org
      end
    end
  end

  describe 'class methods' do
    describe 'find_by' do
      let(:minimal) { Factory(:repository) }

      it "should find a repository by it's id" do
        Repository.find_by(id: minimal.id).id.should == minimal.id
      end

      it "should find a repository by it's name and owner_name" do
        repo = Repository.find_by(name: minimal.name, owner_name: minimal.owner_name)
        repo.owner_name.should == minimal.owner_name
        repo.name.should == minimal.name
      end

      it "returns nil when a repository couldn't be found using params" do
        Repository.find_by(name: 'emptiness').should be_nil
      end
    end

    describe 'timeline' do
      it 'sorts the most repository with the most recent build to the top' do
        one = Factory(:repository, name: 'one', last_build_started_at: '2011-11-11')
        two = Factory(:repository, name: 'two', last_build_started_at: '2011-11-12')

        repositories = Repository.timeline.all
        repositories.first.id.should == two.id
        repositories.last.id.should  == one.id
      end
    end

    describe 'active' do
      let(:active)   { Factory(:repository, active: true) }
      let(:inactive) { Factory(:repository, active: false) }

      it 'contains active repositories' do
        Repository.active.should include(active)
      end

      it 'does not include inactive repositories' do
        Repository.active.should_not include(inactive)
      end
    end

    describe 'search' do
      before(:each) do
        Factory(:repository, name: 'repo 1', last_build_started_at: '2011-11-11')
        Factory(:repository, name: 'repo 2', last_build_started_at: '2011-11-12')
      end

      it 'performs searches case-insensitive' do
        Repository.search('rEpO').to_a.count.should == 2
      end

      it 'performs searches with / entered' do
        Repository.search('fuchs/').to_a.count.should == 2
      end

      it 'performs searches with \ entered' do
        Repository.search('fuchs\\').to_a.count.should == 2
      end
    end

    describe 'by_member' do
      let(:user) { Factory(:user) }
      let(:org)  { Factory(:org) }
      let(:user_repo) { Factory(:repository, owner: user)}
      let(:org_repo)  { Factory(:repository, owner: org, name: 'globalize')}

      before do
        Permission.create!(user: user, repository: user_repo, pull: true, push: true)
        Permission.create!(user: user, repository: org_repo, pull: true)
      end

      it 'returns all repositories a user has rights to' do
        Repository.by_member('svenfuchs').should have(2).items
      end
    end

    describe 'counts_by_owner_names' do
      let!(:repositories) do
        Factory(:repository, owner_name: 'svenfuchs', name: 'minimal')
        Factory(:repository, owner_name: 'travis-ci', name: 'travis-ci')
      end

      it 'returns repository counts per owner_name for the given owner_names' do
        counts = Repository.counts_by_owner_names(%w(svenfuchs travis-ci))
        counts.should == { 'svenfuchs' => 1, 'travis-ci' => 1 }
      end
    end
  end

  describe 'source_url' do
    let(:repo) { Repository.new(owner_name: 'travis-ci', name: 'travis-ci') }

    it 'returns the public git source url for a public repository' do
      repo.private = false
      repo.source_url.should == 'git://github.com/travis-ci/travis-ci.git'
    end

    it 'returns the private git source url for a private repository' do
      repo.private = true
      repo.source_url.should == 'git@github.com:travis-ci/travis-ci.git'
    end
  end

  it "last_build returns the most recent build" do
    repo = Factory(:repository)
    attributes = { repository: repo, state: 'finished' }
    Factory(:build, attributes)
    Factory(:build, attributes)
    build = Factory(:build, attributes)

    repo.last_build.id.should == build.id
  end

  describe 'last_build_result_on' do
    let(:build) { Factory(:build, state: 'finished', config: { 'rvm' => ['1.8.7', '1.9.2'], 'env' => ['DB=sqlite3', 'DB=postgresql'] }) }
    let(:repo)  { build.repository }

    it 'returns last_build_result if params is empty' do
      repo.expects(:last_build_result).returns(2)
      repo.last_build_result_on({}).should == 2
    end

    it 'returns 0 (passing) if all specified builds are passing' do
      build.matrix.each { |job| job.update_attribute(:result, job.config[:rvm] == '1.8.7' ? 0 : 1) }
      repo.last_build_result_on('rvm' => '1.8.7').should == 0
    end

    it 'returns 1 (failing) if at least one specified build is failing' do
      build.matrix.each_with_index { |build, ix| build.update_attribute(:result, ix == 0 ? 1 : 0) }
      repo.last_build_result_on('rvm' => '1.8.7').should == 1
    end
  end

  describe "keys" do
    let(:repo) { Factory(:repository) }

    it "should return the public key" do
      repo.public_key.should == repo.key.public_key
    end

    it "should create a new key when the repository is created" do
      repo = Repository.create!(owner_name: 'travis-ci', name: 'travis-ci')
      repo.key.should_not be_nil
    end
  end

  describe 'branches' do
    let(:repo) { Factory(:repository) }

    it 'returns branches for the given repository' do
      %w(master production).each do |branch|
        2.times { Factory(:build, repository: repo, commit: Factory(:commit, branch: branch)) }
      end
      repo.branches.sort.should == %w(master production)
    end

    it 'is empty for empty repository' do
      repo.branches.should eql []
    end
  end

  describe 'last_finished_builds_by_branches' do
    let(:repo) { Factory(:repository) }

    it 'retrieves last builds on all branches' do
      Build.delete_all
      old = Factory(:build, repository: repo, finished_at: 1.hour.ago,      state: 'finished', commit: Factory(:commit, branch: 'one'))
      one = Factory(:build, repository: repo, finished_at: 1.hour.from_now, state: 'finished', commit: Factory(:commit, branch: 'one'))
      two = Factory(:build, repository: repo, finished_at: 1.hour.from_now, state: 'finished', commit: Factory(:commit, branch: 'two'))

      builds = repo.last_finished_builds_by_branches
      builds.size.should == 2
      builds.should include(one)
      builds.should include(two)
      builds.should_not include(old)
    end
  end
end
