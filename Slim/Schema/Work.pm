package Slim::Schema::Work;


use strict;
use base 'Slim::Schema::DBI';

use Slim::Schema::ResultSet::Work;

use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Strings qw(string);

{
	my $class = __PACKAGE__;

	# Magic to create a ResultSource for this inherited class.
	$class->table('works');

	$class->add_columns(qw(id composer title titlesort titlesearch));
	$class->set_primary_key('id');

	$class->has_many('tracks' => 'Slim::Schema::Track' => 'work');
	$class->belongs_to('composer' => 'Slim::Schema::Composer');

	$class->resultset_class('Slim::Schema::ResultSet::Work');
}

# For saving favorites
sub url {
	my $self = shift;

	return sprintf('db:work.id=%s', Slim::Utils::Misc::escape($self->id));
}

sub name {
	my $self = shift;

	return $self->id || string('UNK');
}

sub namesort {
	my $self = shift;

	return $self->titlesort;
}

sub contributors {
	my $self = shift;

	return $self->contributors->search_related(
		'composer', undef, { distinct => 1 }
	)->search(@_);
}

sub displayAsHTML {
	my ($self, $form, $descend, $sort) = @_;

	$form->{'text'} = $self->title;
}

# Rescan this work.  Make sure at least 1 track for the work exists, otherwise
# delete the work.
sub rescan {
	my ( $class, @ids ) = @_;

	my $dbh = Slim::Schema->dbh;

	my $log = logger('scan.scanner');

	for my $id ( @ids ) {
		my $sth = $dbh->prepare_cached( qq{
			SELECT COUNT(*) FROM tracks WHERE work = ?
		} );
		$sth->execute($id);
		my ($count) = $sth->fetchrow_array;
		$sth->finish;

		if ( !$count ) {
			main::DEBUGLOG && $log->is_debug && $log->debug("Removing unused work: $id");
			$dbh->do( "DELETE FROM works WHERE id = ?", undef, $id );
		}
	}
}

1;

__END__
