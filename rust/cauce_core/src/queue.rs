//! What plays next. Pure bookkeeping: the engine is told what to load by whoever asks the queue.

use std::time::Duration;

/// How far into a track "previous" restarts it instead of going back one.
pub const RESTART_THRESHOLD: Duration = Duration::from_secs(3);

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub enum Repeat {
    #[default]
    Off,
    All,
    One,
}

/// What "previous" decided.
#[derive(Debug, PartialEq, Eq)]
pub enum Back<'a, T> {
    /// Play the current item again from its start.
    Restart(&'a T),
    /// Play this earlier item.
    To(&'a T),
}

/// An ordered list of items and the one playing. Generic so it can be tested without tracks.
#[derive(Clone, Debug)]
pub struct Queue<T> {
    items: Vec<T>,
    current: Option<usize>,
    pub repeat: Repeat,
}

impl<T> Default for Queue<T> {
    fn default() -> Self {
        Self {
            items: Vec::new(),
            current: None,
            repeat: Repeat::Off,
        }
    }
}

impl<T> Queue<T> {
    /// Replaces everything with `items` and makes `start` current. `None` when `start` is out of
    /// range, which leaves the queue empty.
    pub fn replace(&mut self, items: Vec<T>, start: usize) -> Option<&T> {
        self.current = (start < items.len()).then_some(start);
        self.items = if self.current.is_some() { items } else { Vec::new() };
        self.current()
    }

    pub fn current(&self) -> Option<&T> {
        self.items.get(self.current?)
    }

    /// Puts `item` in the current one's place. Nothing happens with nothing current.
    pub fn swap_current(&mut self, item: T) {
        if let Some(index) = self.current {
            self.items[index] = item;
        }
    }

    pub fn index(&self) -> Option<usize> {
        self.current
    }

    pub fn items(&self) -> &[T] {
        &self.items
    }

    /// Makes item `index` current, as a tap on a queue row does.
    pub fn jump(&mut self, index: usize) -> Option<&T> {
        if index >= self.items.len() {
            return None;
        }
        self.current = Some(index);
        self.current()
    }

    /// What the user's "next" plays. Wraps around only under `Repeat::All`; `Repeat::One` does
    /// not hold a user back on one track.
    pub fn skip(&mut self) -> Option<&T> {
        let next = self.after(false)?;
        self.current = Some(next);
        self.current()
    }

    /// What plays once the current item ends by itself: the same one under `Repeat::One`.
    pub fn ended(&mut self) -> Option<&T> {
        let next = self.after(true)?;
        self.current = Some(next);
        self.current()
    }

    /// What follows the current item without moving, for a preload.
    pub fn upcoming(&self) -> Option<&T> {
        self.items.get(self.after(true)?)
    }

    /// The user's "previous" at `position` into the current item.
    pub fn back(&mut self, position: Duration) -> Option<Back<'_, T>> {
        let index = self.current?;
        if position > RESTART_THRESHOLD || index == 0 {
            return self.items.get(index).map(Back::Restart);
        }
        self.current = Some(index - 1);
        self.items.get(index - 1).map(Back::To)
    }

    /// Puts `items` right after the current one, in order. A shuffle only ever mixes what is
    /// already queued, so they still play next with one on.
    pub fn play_next(&mut self, items: Vec<T>) {
        let at = self.current.map_or(0, |index| index + 1);
        self.items.splice(at..at, items);
        self.start_if_empty();
    }

    /// Puts `items` at the end.
    pub fn append(&mut self, items: Vec<T>) {
        self.items.extend(items);
        self.start_if_empty();
    }

    /// Moves the item at `from` to `to`, the current one staying current wherever it lands.
    pub fn move_item(&mut self, from: usize, to: usize) {
        if from >= self.items.len() || to >= self.items.len() {
            return;
        }
        let item = self.items.remove(from);
        self.items.insert(to, item);
        self.current = self.current.map(|current| match current {
            _ if current == from => to,
            _ if from < current && to >= current => current - 1,
            _ if from > current && to <= current => current + 1,
            _ => current,
        });
    }

    /// Mixes what comes after the current item; `pick(n)` answers a slot below `n`.
    pub fn shuffle_upcoming(&mut self, mut pick: impl FnMut(usize) -> usize) {
        let start = self.current.map_or(0, |index| index + 1);
        let Some(upcoming) = self.items.get_mut(start..) else {
            return;
        };
        for last in (1..upcoming.len()).rev() {
            upcoming.swap(last, pick(last + 1) % (last + 1));
        }
    }

    /// Drops the item at `index`, but never the current one.
    pub fn remove(&mut self, index: usize) {
        if index >= self.items.len() || Some(index) == self.current {
            return;
        }
        self.items.remove(index);
        self.current = self.current.map(|current| {
            if index < current {
                current - 1
            } else {
                current
            }
        });
    }

    /// Drops everything after the current item.
    pub fn clear_upcoming(&mut self) {
        if let Some(index) = self.current {
            self.items.truncate(index + 1);
        }
    }

    /// A queue that had nothing current starts at its first item. Nothing is current only when
    /// it was empty.
    fn start_if_empty(&mut self) {
        if self.current.is_none() && !self.items.is_empty() {
            self.current = Some(0);
        }
    }

    /// The index that follows the current one. `natural` is an end the track reached itself,
    /// which `Repeat::One` answers with the same track.
    fn after(&self, natural: bool) -> Option<usize> {
        let index = self.current?;
        match self.repeat {
            Repeat::One if natural => Some(index),
            Repeat::All if index + 1 == self.items.len() => Some(0),
            _ => (index + 1 < self.items.len()).then_some(index + 1),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn queue(items: &[u32], start: usize) -> Queue<u32> {
        let mut queue = Queue::default();
        queue.replace(items.to_vec(), start);
        queue
    }

    #[test]
    fn replace_starts_at_the_chosen_item() {
        let mut queue = Queue::default();
        assert_eq!(queue.replace(vec![1, 2, 3], 1), Some(&2));
        assert_eq!(queue.current(), Some(&2));
    }

    #[test]
    fn replace_out_of_range_leaves_nothing_current() {
        let mut queue = Queue::default();
        assert_eq!(queue.replace(vec![1, 2], 5), None);
        assert_eq!(queue.current(), None);
    }

    #[test]
    fn skip_moves_forward_and_stops_at_the_end() {
        let mut queue = queue(&[1, 2], 0);
        assert_eq!(queue.skip(), Some(&2));
        assert_eq!(queue.skip(), None);
        assert_eq!(queue.current(), Some(&2));
    }

    #[test]
    fn skip_wraps_under_repeat_all() {
        let mut queue = queue(&[1, 2], 1);
        queue.repeat = Repeat::All;
        assert_eq!(queue.skip(), Some(&1));
    }

    #[test]
    fn skip_leaves_a_repeated_track_under_repeat_one() {
        let mut queue = queue(&[1, 2], 0);
        queue.repeat = Repeat::One;
        assert_eq!(queue.skip(), Some(&2));
    }

    #[test]
    fn ended_repeats_the_track_under_repeat_one() {
        let mut queue = queue(&[1, 2], 0);
        queue.repeat = Repeat::One;
        assert_eq!(queue.ended(), Some(&1));
    }

    #[test]
    fn ended_advances_and_stops_after_the_last() {
        let mut queue = queue(&[1, 2], 0);
        assert_eq!(queue.ended(), Some(&2));
        assert_eq!(queue.ended(), None);
    }

    #[test]
    fn upcoming_follows_the_same_rules_as_ended_without_moving() {
        let mut queue = queue(&[1, 2], 1);
        assert_eq!(queue.upcoming(), None);
        queue.repeat = Repeat::All;
        assert_eq!(queue.upcoming(), Some(&1));
        queue.repeat = Repeat::One;
        assert_eq!(queue.upcoming(), Some(&2));
        assert_eq!(queue.current(), Some(&2));
    }

    #[test]
    fn back_restarts_past_the_threshold() {
        let mut queue = queue(&[1, 2], 1);
        assert_eq!(queue.back(Duration::from_secs(10)), Some(Back::Restart(&2)));
        assert_eq!(queue.index(), Some(1));
    }

    #[test]
    fn back_goes_to_the_previous_item_near_the_start() {
        let mut queue = queue(&[1, 2], 1);
        assert_eq!(queue.back(Duration::from_secs(1)), Some(Back::To(&1)));
        assert_eq!(queue.index(), Some(0));
    }

    #[test]
    fn back_on_the_first_item_restarts_it() {
        let mut queue = queue(&[1, 2], 0);
        assert_eq!(queue.back(Duration::ZERO), Some(Back::Restart(&1)));
    }

    #[test]
    fn jump_selects_any_item_in_range() {
        let mut queue = queue(&[1, 2, 3], 0);
        assert_eq!(queue.jump(2), Some(&3));
        assert_eq!(queue.jump(9), None);
        assert_eq!(queue.current(), Some(&3));
    }

    #[test]
    fn replace_out_of_range_keeps_no_items_either() {
        let mut queue = Queue::default();
        queue.replace(vec![1, 2], 5);
        assert!(queue.items().is_empty());
    }

    #[test]
    fn play_next_inserts_after_the_current_item() {
        let mut queue = queue(&[1, 2], 0);
        queue.play_next(vec![8, 9]);
        assert_eq!(queue.items(), &[1, 8, 9, 2]);
        assert_eq!(queue.current(), Some(&1));
    }

    #[test]
    fn play_next_after_a_shuffle_still_plays_next() {
        let mut queue = queue(&[1, 2, 3, 4, 5], 0);
        queue.shuffle_upcoming(|n| n - 1);
        queue.play_next(vec![9]);
        assert_eq!(queue.skip(), Some(&9));
    }

    #[test]
    fn play_next_and_append_on_an_empty_queue_make_the_first_current() {
        let mut queue = Queue::default();
        queue.play_next(vec![7, 8]);
        assert_eq!(queue.current(), Some(&7));
        assert_eq!(queue.items(), &[7, 8]);
        let mut queue = Queue::default();
        queue.append(vec![8, 9]);
        assert_eq!(queue.current(), Some(&8));
        let mut queue = Queue::<u32>::default();
        queue.append(Vec::new());
        assert_eq!(queue.current(), None);
    }

    #[test]
    fn append_adds_at_the_end() {
        let mut queue = queue(&[1], 0);
        queue.append(vec![2, 3]);
        assert_eq!(queue.items(), &[1, 2, 3]);
        assert_eq!(queue.current(), Some(&1));
    }

    #[test]
    fn a_track_already_queued_is_added_again() {
        let mut queue = queue(&[1, 2], 0);
        queue.play_next(vec![1]);
        queue.append(vec![2]);
        assert_eq!(queue.items(), &[1, 1, 2, 2]);
        assert_eq!(queue.index(), Some(0));
    }

    #[test]
    fn moving_an_item_keeps_the_current_one_current() {
        let mut queue = queue(&[1, 2, 3, 4], 1);
        queue.move_item(3, 0);
        assert_eq!(queue.items(), &[4, 1, 2, 3]);
        assert_eq!(queue.current(), Some(&2));
        queue.move_item(2, 3);
        assert_eq!(queue.items(), &[4, 1, 3, 2]);
        assert_eq!(queue.current(), Some(&2));
        queue.move_item(9, 0);
        assert_eq!(queue.items(), &[4, 1, 3, 2]);
    }

    #[test]
    fn shuffling_mixes_only_what_comes_after_the_current_one() {
        let mut queue = queue(&[1, 2, 3, 4, 5], 1);
        // Always picks the first remaining slot: reverses the upcoming ones.
        queue.shuffle_upcoming(|_| 0);
        assert_eq!(&queue.items()[..2], &[1, 2]);
        assert_eq!(queue.current(), Some(&2));
        let mut rest = queue.items()[2..].to_vec();
        rest.sort();
        assert_eq!(rest, vec![3, 4, 5]);
    }

    #[test]
    fn clearing_the_upcoming_keeps_what_played_and_the_current_one() {
        let mut queue = queue(&[1, 2, 3, 4], 1);
        queue.clear_upcoming();
        assert_eq!(queue.items(), &[1, 2]);
        assert_eq!(queue.current(), Some(&2));
    }

    #[test]
    fn removing_an_item_keeps_the_current_one_current() {
        let mut queue = queue(&[1, 2, 3, 4], 2);
        queue.remove(0);
        assert_eq!(queue.items(), &[2, 3, 4]);
        assert_eq!(queue.current(), Some(&3));
        queue.remove(2);
        assert_eq!(queue.items(), &[2, 3]);
        assert_eq!(queue.current(), Some(&3));
        // The current one stays: playing on is not a removal.
        queue.remove(1);
        assert_eq!(queue.items(), &[2, 3]);
    }
}
