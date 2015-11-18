require "spec_helper"

import java.util.logging.Logger
import java.util.logging.Level

describe Ecco::Client do
  subject do
    described_class.new(
      username: DatabaseHelper::USER,
      password: DatabaseHelper::PASS,
    )
  end

  let(:table_name)   { :ecco_test_table }
  let(:column_value) { "a value" }
  let(:mysql_row)    { { column1: column_value } }

  before(:all) do
    root_logger = Logger.get_logger("");
    # The first handler is by default the console
    root_logger.get_handlers.first.set_level(Level::WARNING)
  end

  before do
    DatabaseHelper.create_table(table_name, columns: 1)
  end

  after do
    DatabaseHelper.drop_table(table_name)
  end

  describe "#start_in_thread" do
    context "when called multiple times" do
      it "should throw an error" do
        subject.start_in_thread

        expect { subject.start_in_thread }.to raise_error(java.util.concurrent.TimeoutException)

        subject.stop
      end
    end
  end

  describe "#stop" do
    context "when called multiple times" do
      it "should not throw an error" do
        subject.start_in_thread

        subject.stop
        expect { subject.stop }.not_to raise_error
      end
    end

    context "when called before started" do
      it "should not throw an error" do
        expect { subject.stop }.not_to raise_error
      end
    end
  end

  describe "#set_binlog_filename, #set_binlog_position" do
    context "when position and filename is set" do
      let(:old_position) do
        another_client = described_class.new(
          username: DatabaseHelper::USER,
          password: DatabaseHelper::PASS,
        )

        TestHelper.wait_for_save_position_events(another_client) do
          DatabaseHelper.insert(table_name, mysql_row)
        end
      end

      before do
        subject.set_binlog_position(old_position.fetch(:position))
        subject.set_binlog_filename(old_position.fetch(:filename))

        DatabaseHelper.flush_logs
        DatabaseHelper.insert(table_name, mysql_row)
      end

      it "should start at that position" do
        subject_position = TestHelper.wait_for_save_position_events(subject)

        expect(subject_position).to eq(old_position)
      end
    end
  end

  describe "#on_row_event" do
    context "when a row is inserted" do
      let(:row_event) do
        TestHelper.wait_for_row_events(subject) do
          DatabaseHelper.insert(table_name, mysql_row)
        end
      end

      it "should receive a row event with correct type" do
        expect(row_event.type).to eq("WRITE_ROWS")
      end

      it "should receive a row event with the inserted row" do
        value_from_event = row_event.rows.first[1]

        expect(value_from_event).to eq(column_value)
      end
    end

    context "when a row is updated" do
      let(:update_value)   { "another value" }
      let(:update_columns) { { column1: update_value } }
      let(:row_event) do
        id = DatabaseHelper.insert(table_name, mysql_row)

        TestHelper.wait_for_row_events(subject) do
          DatabaseHelper.update(table_name, id: id, columns: update_columns )
        end
      end

      it "should receive a row event with correct type" do
        expect(row_event.type).to eq("UPDATE_ROWS")
      end

      it "should receive a row event with the old and updated row" do
        value_before_update = row_event.rows.first.key[1]
        value_after_update  = row_event.rows.first.value[1]

        expect(value_before_update).to eq(column_value)
        expect(value_after_update).to eq(update_value)
      end
    end

    context "when a row is deleted" do
      let(:row_event) do
        id = DatabaseHelper.insert(table_name, mysql_row)

        TestHelper.wait_for_row_events(subject) do
          DatabaseHelper.delete(table_name, id: id)
        end
      end

      it "should receive a row event with correct type" do
        expect(row_event.type).to eq("DELETE_ROWS")
      end

      it "should receive a row event with the deleted row" do
        value_from_event = row_event.rows.first[1]

        expect(value_from_event).to eq(column_value)
      end
    end

    context "when there are multiple tables" do
      before do
        DatabaseHelper.create_table(another_table, columns: 2)
      end

      let(:another_table) { :another_table_name }
      let(:row_events) do
        TestHelper.wait_for_row_events(subject, count: 2) do
          DatabaseHelper.insert(table_name, mysql_row)
          DatabaseHelper.insert(another_table, mysql_row)
        end
      end

      it "should receive events for all tables" do
        expect(row_events.first.table).to eq(table_name.to_s)
        expect(row_events.last.table).to eq(another_table.to_s)
      end
    end

    context "when the log files are rotated" do
      let(:event_count) { 10 }
      let(:row_events) do
        TestHelper.wait_for_row_events(subject, count: event_count) do
          1.upto(event_count) do |i|
            DatabaseHelper.insert(table_name, mysql_row)
            DatabaseHelper.flush_logs if i == 1
          end
        end
      end

      it "should still receive events" do
        expect(row_events.count).to eq(event_count)
      end
    end
  end

  describe "#on_save_position" do
    context "when there are multiple events after each other" do
      let(:event_count) { 10 }
      let(:save_events) do
        TestHelper.wait_for_save_position_events(subject, count: event_count) do
          1.upto(event_count) do |i|
            DatabaseHelper.insert(table_name, mysql_row)
          end
        end
      end

      it "should receive an incrementing file position" do
        positions = save_events.map { |event| event.fetch(:position) }

        expect(positions).to eq(positions.sort)
      end
    end

    context "when the log files are rotated" do
      let(:event_count) { 10 }
      let(:save_events) do
        TestHelper.wait_for_save_position_events(subject, count: event_count) do
          1.upto(event_count) do |i|
            DatabaseHelper.insert(table_name, mysql_row)
            DatabaseHelper.flush_logs if i == 1
          end
        end
      end

      it "should received a new log file" do
        logfile1 = save_events.first.fetch(:filename)
        logfile2 = save_events.last.fetch(:filename)

        expect(logfile1).not_to eq(logfile2)
      end
    end
  end

  describe "#start" do
    context "when given a non-existent server" do
      subject do
        described_class.new(
          hostname: "somewhere_over_the_rainbow",
          username: DatabaseHelper::USER,
          password: DatabaseHelper::PASS,
        )
      end

      it "will raise an error" do
        expect { subject.start }.to raise_error(Ecco::Error::ConnectionError)
      end
    end

    context "when given bad credentials" do
      subject do
        described_class.new(
          username: DatabaseHelper::USER,
          password: "this_is_not_the_password",
        )
      end

      it "will raise an error" do
        expect { subject.start }.to raise_error(Ecco::Error::ConnectionError)
      end
    end
  end

end
